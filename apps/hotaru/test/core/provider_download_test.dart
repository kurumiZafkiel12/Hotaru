import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/clash_rule_sets.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/encoding.dart';
import 'package:hotaru/core/provider_download.dart';
import 'package:hotaru/core/routed_http.dart';

void main() {
  Future<HttpServer> server(void Function(HttpRequest) handle) async {
    final result = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    result.listen(handle);
    addTearDown(() => result.close(force: true));
    return result;
  }

  Uri url(HttpServer server, [String path = '/']) =>
      Uri.parse('http://127.0.0.1:${server.port}$path');

  CoreProxyProviderRequest proxy(
    Uri uri, {
    String? outbound,
    Map<String, List<String>> headers = const {},
    int maxBytes = 4096,
    Duration timeout = const Duration(seconds: 3),
  }) => CoreProxyProviderRequest(
    index: 0,
    name: 'fixture',
    kind: CoreProxyProviderKind.http,
    url: uri,
    path: null,
    outbound: outbound,
    interval: const Duration(hours: 1),
    timeout: timeout,
    maxBytes: maxBytes,
    headers: headers,
  );

  Matcher code(String value) =>
      isA<CoreAdapterException>().having((error) => error.code, 'code', value);

  test(
    'HTTP payload preserves metadata and application headers on the current route',
    () async {
      final transport = _Transport();
      final origin = await server((request) {
        expect(request.headers.value('user-agent'), 'Hotaru-fixture');
        expect(request.headers.value('x-fixture'), 'present');
        request.response
          ..headers.set('etag', 'fixture-etag')
          ..headers.set('last-modified', 'Wed, 04 Nov 2026 00:00:00 GMT')
          ..headers.set(
            'subscription-userinfo',
            'upload=1; download=2; total=3',
          )
          ..add(utf8.encode('proxies: [] # 中文'));
        unawaited(request.response.close());
      });
      final loader = CoreProviderDownloader(
        transport: transport,
        userAgent: 'Hotaru-fixture',
      );
      final payload = await loader.loadProxy(
        proxy(
          url(origin),
          headers: {
            'X-Fixture': ['present'],
          },
        ),
      );
      expect(payload.text, 'proxies: [] # 中文');
      expect(payload.etag, 'fixture-etag');
      expect(payload.subscriptionInfo, contains('total=3'));
      expect(payload.lastModified, startsWith('Wed'));
      expect(payload.fetchedAt.isUtc, isTrue);
      expect(payload.finalUrl, url(origin));
      expect(transport.outbounds, [null]);
      expect(transport.closed, 1);
    },
  );

  test(
    'cross-origin redirects remove credentials while same-origin redirects retain them',
    () async {
      final auth = <String?>[];
      final cookies = <String?>[];
      final destination = await server((request) {
        auth.add(request.headers.value('authorization'));
        cookies.add(request.headers.value('cookie'));
        request.response.write('done');
        unawaited(request.response.close());
      });
      late HttpServer source;
      source = await server((request) {
        auth.add(request.headers.value('authorization'));
        cookies.add(request.headers.value('cookie'));
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            'location',
            request.uri.path == '/first'
                ? '/second'
                : url(destination).toString(),
          );
        unawaited(request.response.close());
      });
      final payload = await CoreProviderDownloader(transport: _Transport())
          .loadProxy(
            proxy(
              url(source, '/first').replace(userInfo: 'name:secret'),
              headers: {
                'Cookie': ['session=private'],
              },
            ),
          );
      expect(auth, [
        'Basic ${base64Encode(utf8.encode('name:secret'))}',
        'Basic ${base64Encode(utf8.encode('name:secret'))}',
        null,
      ]);
      expect(cookies, ['session=private', 'session=private', null]);
      expect(payload.finalUrl, url(destination));
      expect(payload.finalUrl!.userInfo, isEmpty);
    },
  );

  test(
    'source route names require explicit bindings and DIRECT cannot be remapped',
    () async {
      final transport = _Transport();
      final origin = await server((request) {
        request.response.write('payload');
        unawaited(request.response.close());
      });
      final loader = CoreProviderDownloader(
        transport: transport,
        outboundBindings: {'source': 'committed-target', 'DIRECT': 'wrong'},
      );
      await expectLater(
        loader.loadProxy(proxy(url(origin), outbound: 'missing')),
        throwsA(code('provider_route_binding_required')),
      );
      expect(transport.outbounds, isEmpty);
      await loader.loadProxy(proxy(url(origin), outbound: 'source'));
      await loader.loadProxy(proxy(url(origin), outbound: 'DIRECT'));
      expect(transport.outbounds, ['committed-target', 'DIRECT']);
    },
  );

  test(
    'status, byte bounds and malformed UTF8 do not return partial or stale payloads',
    () async {
      final transport = _Transport();
      final origin = await server((request) {
        if (request.uri.path == '/status') {
          request.response.statusCode = 503;
        } else if (request.uri.path == '/utf8') {
          request.response.add([0xff]);
        } else {
          request.response.add(List.filled(17, 65));
        }
        unawaited(request.response.close());
      });
      final loader = CoreProviderDownloader(transport: transport);
      await expectLater(
        loader.loadProxy(proxy(url(origin, '/status'))),
        throwsA(code('provider_http')),
      );
      await expectLater(
        loader.loadProxy(proxy(url(origin), maxBytes: 16)),
        throwsA(isA<CoreConfigSizeException>()),
      );
      await expectLater(
        loader.loadProxy(proxy(url(origin, '/utf8'))),
        throwsA(code('invalid_provider_encoding')),
      );
      expect(transport.closed, 3);
    },
  );

  test('redirect credentials and redirect loops are rejected', () async {
    final origin = await server((request) {
      request.response
        ..statusCode = 302
        ..headers.set(
          'location',
          request.uri.path == '/credentials'
              ? 'http://user:secret@127.0.0.1/'
              : '/loop',
        );
      unawaited(request.response.close());
    });
    final loader = CoreProviderDownloader(transport: _Transport());
    await expectLater(
      loader.loadProxy(proxy(url(origin, '/credentials'))),
      throwsA(code('unsafe_provider_redirect')),
    );
    await expectLater(
      loader.loadProxy(proxy(url(origin, '/loop'))),
      throwsA(code('invalid_provider_redirect')),
    );
  });

  test(
    'invalid headers are refused before transport and transport failures hide private URLs',
    () async {
      final transport = _Transport();
      final loader = CoreProviderDownloader(transport: transport);
      final uri = Uri.parse('http://127.0.0.1/private?token=secret');
      for (final headers in [
        {
          'Connection': ['keep-alive'],
        },
        {
          'X-Test': ['line\r\ninjection'],
        },
        {
          'x-test': ['a'],
          'X-Test': ['b'],
        },
      ]) {
        await expectLater(
          loader.loadProxy(proxy(uri, headers: headers)),
          throwsA(code('invalid_provider_headers')),
        );
      }
      expect(transport.outbounds, isEmpty);
      transport.failure = const HttpException('private?token=secret');
      await expectLater(
        loader.loadProxy(proxy(uri)),
        throwsA(code('provider_transport')),
      );
    },
  );

  test(
    'rule providers share routed HTTP and timeout closes the owned client',
    () async {
      final transport = _Transport();
      final origin = await server((request) {
        if (request.uri.path == '/slow') return;
        request.response.write('payload:\n  - example.com');
        unawaited(request.response.close());
      });
      final loader = CoreProviderDownloader(transport: transport);
      final result = await loader.loadRule(
        CoreRuleProviderRequest(
          name: 'rules',
          index: 0,
          url: url(origin),
          path: null,
          outbound: null,
          format: 'yaml',
          behavior: 'domain',
          interval: const Duration(hours: 1),
          timeout: const Duration(seconds: 2),
          maxBytes: 1024,
        ),
      );
      expect(result.text, contains('example.com'));
      await expectLater(
        loader.loadProxy(
          proxy(
            url(origin, '/slow'),
            timeout: const Duration(milliseconds: 100),
          ),
        ),
        throwsA(code('timeout')),
      );
      expect(transport.closed, 2);
    },
  );
}

final class _Transport implements CoreRoutedHttp {
  final List<String?> outbounds = [];
  int closed = 0;
  Exception? failure;

  @override
  Future<T> withRoutedClient<T>(
    Future<T> Function(HttpClient) action, {
    String? outbound,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    outbounds.add(outbound);
    if (failure case final error?) throw error;
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      return await action(client).timeout(timeout);
    } finally {
      client.close(force: true);
      closed++;
    }
  }
}

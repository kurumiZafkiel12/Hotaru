import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/clash_rule_sets.dart';
import 'package:hotaru/core/provider_cache.dart';
import 'package:hotaru/core/provider_download.dart';
import 'package:hotaru/core/routed_http.dart';

class _Transport implements CoreRoutedHttp {
  @override
  Future<T> withRoutedClient<T>(
    Future<T> Function(HttpClient) action, {
    String? outbound,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      return await action(client).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

void main() {
  late Directory directory;
  late CoreProviderCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hotaru-provider-cache-');
    cache = await CoreProviderCache.open(directory.path);
  });
  tearDown(() => directory.delete(recursive: true));

  Future<HttpServer> server(void Function(HttpRequest) handle) async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen(handle);
    addTearDown(() => origin.close(force: true));
    return origin;
  }

  Uri url(HttpServer origin) =>
      Uri.parse('http://127.0.0.1:${origin.port}/provider');
  CoreProxyProviderRequest request(
    Uri uri, {
    Map<String, List<String>> headers = const {},
  }) => CoreProxyProviderRequest(
    index: 0,
    name: 'fixture',
    kind: CoreProxyProviderKind.http,
    url: uri,
    path: null,
    outbound: null,
    interval: const Duration(hours: 1),
    timeout: const Duration(seconds: 3),
    maxBytes: 4096,
    headers: headers,
  );
  CoreCachedProviderLoader loader({DateTime Function()? now}) =>
      CoreCachedProviderLoader(
        downloader: CoreProviderDownloader(transport: _Transport()),
        cache: cache,
        now: now,
      );
  const key =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  test(
    'cache persists exact UTF-8 bytes and rejects corruption, bad keys and excess bytes',
    () async {
      final payload = CoreProviderPayload(
        text: 'proxies: [] # 中文',
        fetchedAt: DateTime.now().toUtc(),
        etag: 'v1',
        finalUrl: Uri.parse('https://provider.invalid/source'),
      );
      await cache.write(key, payload, 4096);
      final reopened = await CoreProviderCache.open(directory.path);
      final stored = (await reopened.read(key, 4096))!;
      expect(stored.text, payload.text);
      expect(stored.fetchedAt, payload.fetchedAt);
      expect(stored.etag, 'v1');
      expect(stored.finalUrl, payload.finalUrl);
      expect(await reopened.read(key, 1), isNull);
      expect(() => cache.read('../outside', 4096), throwsArgumentError);
      final file = File('${directory.path}/$key.cache');
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 1] ^= 1;
      await file.writeAsBytes(bytes);
      expect(await reopened.read(key, 4096), isNull);
      await expectLater(
        cache.write(key, payload, 1),
        throwsA(isA<CoreAdapterException>()),
      );
    },
  );

  test(
    'entry limits evict old bodies and failed writes do not poison later writes',
    () async {
      cache = await CoreProviderCache.open(
        directory.path,
        maxEntries: 2,
        maxBytes: 2048,
      );
      for (final letter in ['a', 'b', 'c']) {
        await cache.write(
          List.filled(64, letter).join(),
          CoreProviderPayload(text: letter, fetchedAt: DateTime.now().toUtc()),
          4096,
        );
      }
      final files = await directory
          .list()
          .where((file) => file.path.endsWith('.cache'))
          .toList();
      expect(files, hasLength(2));
      expect(await cache.read(List.filled(64, 'c').join(), 4096), isNotNull);
      await expectLater(
        cache.write(
          key,
          CoreProviderPayload(
            text: List.filled(3000, 'x').join(),
            fetchedAt: DateTime.now().toUtc(),
          ),
          4096,
        ),
        throwsA(isA<CoreAdapterException>()),
      );
      await cache.write(
        key,
        CoreProviderPayload(
          text: 'recovered',
          fetchedAt: DateTime.now().toUtc(),
        ),
        4096,
      );
      expect((await cache.read(key, 4096))!.text, 'recovered');
    },
  );

  test(
    'fresh payload survives loader recreation and forced 304 retains actual fetch time',
    () async {
      var receipts = 0;
      final origin = await server((incoming) {
        receipts++;
        incoming.response.headers.set('etag', 'version-1');
        if (receipts == 1) {
          incoming.response.write('proxies: []');
        } else {
          expect(
            incoming.headers.value(HttpHeaders.ifNoneMatchHeader),
            'version-1',
          );
          incoming.response.statusCode = HttpStatus.notModified;
        }
        unawaited(incoming.response.close());
      });
      final source = request(url(origin));
      final first = await loader().loadProxy(source);
      expect((await loader().loadProxy(source)).text, first.text);
      expect(receipts, 1);
      final validated = await loader().loadProxy(source, force: true);
      expect(validated.fetchedAt, first.fetchedAt);
      expect(validated.validatedAt, isNotNull);
      expect(validated.text, first.text);
      expect(
        (await loader().loadProxy(source)).validatedAt,
        validated.validatedAt,
      );
      expect(receipts, 2);
    },
  );

  test(
    'expired payload refetches and failed forced refresh preserves the usable disk entry',
    () async {
      var receipts = 0;
      var fail = false;
      final origin = await server((incoming) {
        receipts++;
        if (fail) {
          incoming.response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          incoming.response.write('revision-$receipts');
        }
        unawaited(incoming.response.close());
      });
      final source = request(url(origin));
      final first = await loader().loadProxy(source);
      final second = await loader(
        now: () => first.fetchedAt.add(const Duration(hours: 2)),
      ).loadProxy(source);
      expect(second.text, 'revision-2');
      fail = true;
      await expectLater(
        loader().loadProxy(source, force: true),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.status,
            'status',
            503,
          ),
        ),
      );
      expect((await loader().loadProxy(source)).text, 'revision-2');
      expect(receipts, 3);
    },
  );

  test(
    'account headers partition persisted data instead of reusing another subscription',
    () async {
      var receipts = 0;
      final origin = await server((incoming) {
        receipts++;
        incoming.response.write(incoming.headers.value('authorization'));
        unawaited(incoming.response.close());
      });
      final first = request(
        url(origin),
        headers: {
          'authorization': ['Bearer first-account'],
        },
      );
      final second = request(
        url(origin),
        headers: {
          'authorization': ['Bearer second-account'],
        },
      );
      expect((await loader().loadProxy(first)).text, 'Bearer first-account');
      expect((await loader().loadProxy(second)).text, 'Bearer second-account');
      expect((await loader().loadProxy(first)).text, 'Bearer first-account');
      expect(receipts, 2);
      final names = await directory.list().map((file) => file.path).toList();
      expect(names.any((name) => name.contains('account')), isFalse);
    },
  );

  test(
    'validators are sent only to the cached final URL through redirects',
    () async {
      var destinationReceipts = 0;
      final destination = await server((incoming) {
        destinationReceipts++;
        incoming.response.headers.set('etag', 'destination-v1');
        if (destinationReceipts == 1) {
          incoming.response.write('destination-body');
        } else {
          expect(
            incoming.headers.value(HttpHeaders.ifNoneMatchHeader),
            'destination-v1',
          );
          incoming.response.statusCode = HttpStatus.notModified;
        }
        unawaited(incoming.response.close());
      });
      final origin = await server((incoming) {
        expect(incoming.headers.value(HttpHeaders.ifNoneMatchHeader), isNull);
        incoming.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, url(destination));
        unawaited(incoming.response.close());
      });
      final source = request(url(origin));
      final first = await loader().loadProxy(source);
      final second = await loader().loadProxy(source, force: true);
      expect(second.text, first.text);
      expect(second.finalUrl, url(destination));
      expect(destinationReceipts, 2);
    },
  );

  test(
    'proxy and rule cache entries stay separate across loader recreation',
    () async {
      var receipts = 0;
      final origin = await server((incoming) {
        receipts++;
        incoming.response.write('observed-$receipts');
        unawaited(incoming.response.close());
      });
      final proxy = request(url(origin));
      final rule = CoreRuleProviderRequest(
        name: 'rule',
        index: 0,
        url: url(origin),
        path: null,
        outbound: null,
        format: 'yaml',
        behavior: 'domain',
        interval: const Duration(hours: 1),
        timeout: const Duration(seconds: 3),
        maxBytes: 4096,
      );
      expect((await loader().loadProxy(proxy)).text, 'observed-1');
      expect((await loader().loadRule(rule)).text, 'observed-2');
      expect((await loader().loadRule(rule)).text, 'observed-2');
      expect(receipts, 2);
    },
  );

  test(
    'cache file symlinks are ignored rather than read as provider data',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'hotaru-cache-outside-',
      );
      addTearDown(() => outside.delete(recursive: true));
      final data = File('${outside.path}/outside.cache');
      await data.writeAsString('outside');
      await Link('${directory.path}/$key.cache').create(data.path);
      expect(await cache.read(key, 4096), isNull);
      expect(await data.readAsString(), 'outside');
    },
    skip: Platform.isWindows
        ? 'Windows symlink creation requires an additional OS capability'
        : false,
  );

  test(
    'an unsolicited 304 is never treated as a successful download',
    () async {
      final origin = await server((incoming) {
        incoming.response.statusCode = HttpStatus.notModified;
        unawaited(incoming.response.close());
      });
      await expectLater(
        loader().loadProxy(request(url(origin))),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.status,
            'status',
            304,
          ),
        ),
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );
}

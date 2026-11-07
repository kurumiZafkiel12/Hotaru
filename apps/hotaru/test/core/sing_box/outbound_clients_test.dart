import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/probe_listener.dart';
import 'package:hotaru/core/outbound_http.dart';
import 'package:hotaru/core/sing_box/clash_api_adapter.dart';
import 'package:hotaru/core/sing_box/outbound_http.dart';

void main() {
  const probe = CoreProbeListenerSpec(
    port: 17891,
    secret: 'fixture-only-12345678901234567890123456789',
  );

  for (final ending in ['complete', 'failure', 'timeout', 'close']) {
    test('scoped client factory is terminal after $ending', () async {
      final source = SingBoxOutboundHttp(listener: probe, outbounds: ['A']);
      addTearDown(source.close);
      late CoreOutboundClients saved;
      late HttpClient created;
      final release = Completer<int>();
      final result = source.withOutboundClients('A', (clients) async {
        saved = clients;
        created = clients.createClient();
        final second = clients.createClient();
        expect(identical(second, created), isFalse);
        if (ending == 'failure') throw StateError('fixture failure');
        if (ending == 'complete') return 1;
        if (ending == 'close') source.close();
        return release.future;
      }, timeout: const Duration(milliseconds: 20));
      if (ending == 'complete') {
        expect(await result, 1);
      } else if (ending == 'failure') {
        await expectLater(result, throwsStateError);
      } else {
        await expectLater(result, throwsA(isA<CoreAdapterException>()));
        release.complete(1);
      }
      expect(
        saved.createClient,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'closed',
          ),
        ),
      );
      expect(
        () => created.getUrl(Uri.parse('http://127.0.0.1:1')),
        throwsStateError,
      );
    });
  }

  test(
    'controller resolves a group once and scopes every client to that leaf',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var reads = 0;
      var selected = 'A';
      server.listen((request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/proxies');
        reads++;
        request.response.write(
          jsonEncode({
            'proxies': {
              'group': {
                'type': 'Selector',
                'now': selected,
                'all': ['A', 'B'],
              },
              'A': {'type': 'Http'},
              'B': {'type': 'Http'},
            },
          }),
        );
        await request.response.close();
      });
      final adapter = SingBoxClashApiAdapter(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        secret: 'fixture',
        probe: probe,
        probeOutbounds: ['A', 'B', 'group'],
      );
      addTearDown(adapter.close);
      late CoreOutboundClients retained;
      await adapter.withOutboundClients('group', (clients) async {
        retained = clients;
        expect(clients.chain, ['group', 'A']);
        selected = 'B';
        clients.createClient().close(force: true);
        clients.createClient().close(force: true);
        expect(clients.chain.last, 'A');
      });
      expect(reads, 1);
      expect(retained.createClient, throwsA(isA<CoreAdapterException>()));
      await adapter.withOutboundClients(
        'group',
        (clients) async => expect(clients.chain, ['group', 'B']),
      );
      expect(reads, 2);
      await expectLater(
        adapter.withOutboundClients(
          'unknown',
          (_) async => fail('must not execute'),
        ),
        throwsA(isA<CoreAdapterException>()),
      );
      selected = 'group';
      await expectLater(
        adapter.withOutboundClients(
          'group',
          (_) async => fail('must not execute'),
        ),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'selection_unavailable',
          ),
        ),
      );
    },
  );
}

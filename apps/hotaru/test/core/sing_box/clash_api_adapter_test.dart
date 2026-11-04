import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/sing_box/clash_api_adapter.dart';

void main() {
  late HttpServer server;
  late SingBoxClashApiAdapter adapter;
  late Future<void> Function(HttpRequest request) handler;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    adapter = SingBoxClashApiAdapter(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      secret: 'fixture-secret',
    );
    handler = (request) async {
      request.response.statusCode = 500;
      await request.response.close();
    };
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer fixture-secret');
      await handler(request);
    });
  });

  tearDown(() async {
    adapter.close();
    await server.close(force: true);
  });

  test('controller rejects non-loopback hosts and embedded credentials', () {
    for (final endpoint in [
      'http://example.com:9090',
      'http://127.0.0.1:9090/private',
      'http://secret@127.0.0.1:9090',
      'http://127.0.0.1',
    ]) {
      expect(
        () =>
            SingBoxClashApiAdapter(endpoint: Uri.parse(endpoint), secret: 's'),
        throwsArgumentError,
      );
    }
  });

  test('node selection preserves encoded names in path and JSON', () async {
    handler = (request) async {
      expect(request.method, 'PUT');
      expect(request.uri.pathSegments, ['proxies', '香港 / AI']);
      expect(jsonDecode(await utf8.decoder.bind(request).join()), {
        'name': '日本 / 01',
      });
      request.response.statusCode = 204;
      await request.response.close();
    };
    await adapter.selectOutbound('香港 / AI', '日本 / 01');
  });

  test('rejects HTTP delay before sending any request', () async {
    await expectLater(
      adapter.delay(
        'node',
        Uri.parse('http://example.com'),
        const Duration(seconds: 1),
      ),
      throwsArgumentError,
    );
  });

  test(
    'failed delay remains an API error rather than a node verdict',
    () async {
      handler = (request) async {
        expect(request.uri.pathSegments, ['proxies', 'JP', 'delay']);
        expect(
          request.uri.queryParameters['url'],
          'https://example.com/check?a=b',
        );
        request.response.statusCode = 503;
        request.response.write('internal diagnostic not exposed');
        await request.response.close();
      };
      await expectLater(
        adapter.delay(
          'JP',
          Uri.parse('https://example.com/check?a=b'),
          const Duration(seconds: 1),
        ),
        throwsA(
          isA<CoreAdapterException>()
              .having((error) => error.code, 'code', 'http')
              .having((error) => error.status, 'status', 503),
        ),
      );
    },
  );

  test(
    'does not forward bearer credentials through controller redirects',
    () async {
      handler = (request) async {
        request.response.statusCode = 302;
        request.response.headers.set('location', 'http://example.com/');
        await request.response.close();
      };
      await expectLater(
        adapter.outbounds(),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.status,
            'status',
            302,
          ),
        ),
      );
    },
  );

  test(
    'missing process data stays unknown while counters and chains survive',
    () async {
      handler = (request) async {
        request.response.write(
          jsonEncode({
            'uploadTotal': 105,
            'downloadTotal': 206,
            'connections': [
              {
                'id': 'connection-1',
                'metadata': {
                  'type': 'mixed/local',
                  'network': 'tcp',
                  'host': 'example.com',
                  'destinationIP': '203.0.113.1',
                  'destinationPort': '443',
                  'processPath': '',
                },
                'chains': ['node', 'selected'],
                'rule': 'final',
                'upload': 100,
                'download': 200,
              },
            ],
          }),
        );
        await request.response.close();
      };
      final snapshot = await adapter.connections();
      expect(snapshot.uploadTotal, 105);
      expect(snapshot.entries.single.processPath, isNull);
      expect(snapshot.entries.single.chain, ['node', 'selected']);
      expect(snapshot.entries.single.download, 200);
    },
  );

  test('malformed or negative counters never become valid traffic', () async {
    handler = (request) async {
      request.response.write(
        '{"connections":[],"uploadTotal":-1,"downloadTotal":0}',
      );
      await request.response.close();
    };
    await expectLater(
      adapter.connections(),
      throwsA(
        isA<CoreAdapterException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('close is terminal and idempotent', () async {
    adapter.close();
    adapter.close();
    await expectLater(
      adapter.outbounds(),
      throwsA(
        isA<CoreAdapterException>().having(
          (error) => error.code,
          'code',
          'closed',
        ),
      ),
    );
  });
}

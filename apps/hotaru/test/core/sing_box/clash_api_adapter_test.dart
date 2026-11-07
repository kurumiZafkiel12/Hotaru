import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/routing_mode.dart';
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
    await adapter.close();
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

  test('mode writes use PATCH and require a matching readback', () async {
    var mode = 'rule';
    var writes = 0;
    handler = (request) async {
      expect(request.uri.path, '/configs');
      if (request.method == 'PATCH') {
        writes++;
        mode =
            (jsonDecode(await utf8.decoder.bind(request).join()) as Map)['mode']
                as String;
        request.response.statusCode = 204;
      } else {
        expect(request.method, 'GET');
        request.response.write(jsonEncode({'mode': mode}));
      }
      await request.response.close();
    };
    for (final value in CoreRoutingMode.values) {
      await adapter.setRoutingMode(value);
      expect(await adapter.routingMode(), value);
    }
    expect(writes, 3);
    mode = 'unsupported';
    await expectLater(
      adapter.routingMode(),
      throwsA(
        isA<CoreAdapterException>().having(
          (error) => error.code,
          'code',
          'unsupported_routing_mode',
        ),
      ),
    );
  });

  test(
    'a successful mode response without applied state is not accepted',
    () async {
      handler = (request) async {
        if (request.method == 'PATCH') {
          await utf8.decoder.bind(request).join();
          request.response.statusCode = 204;
        } else {
          request.response.write('{"mode":"rule"}');
        }
        await request.response.close();
      };
      await expectLater(
        adapter.setRoutingMode(CoreRoutingMode.global),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'route_changed',
          ),
        ),
      );
    },
  );

  test('rejects invalid delay targets before sending a request', () async {
    var requests = 0;
    handler = (request) async {
      requests++;
      await request.response.close();
    };
    for (final target in [
      'ftp://example.com',
      'https:///path',
      'https://user:password@example.com',
      'https://example.com/#fragment',
      'http://example.com:0',
      'http://example.com:65536',
    ]) {
      await expectLater(
        adapter.delay('node', Uri.parse(target), const Duration(seconds: 1)),
        throwsArgumentError,
      );
    }
    expect(requests, 0);
  });

  test(
    'HTTP delay requires scoped clients instead of silently using the native API default',
    () async {
      var requests = 0;
      handler = (request) async {
        requests++;
        await request.response.close();
      };
      await expectLater(
        adapter.delay(
          '日本 / A',
          Uri.parse('http://example.com:8080/check?a=b'),
          const Duration(seconds: 1),
        ),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'outbound_http_unavailable',
          ),
        ),
      );
      expect(requests, 0);
    },
  );

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
    await adapter.close();
    await adapter.close();
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

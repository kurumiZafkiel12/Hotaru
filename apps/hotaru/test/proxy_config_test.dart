import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/mihomo_api.dart';
import 'package:hotaru/core/proxy_config.dart';
import 'package:hotaru/profiles/importer.dart';

void main() {
  const profile = {
    'proxies': [
      {'name': 'a', 'type': 'socks5', 'server': '127.0.0.1', 'port': 1080},
      {'name': 'b', 'type': 'ss', 'server': 'example.com', 'port': 8388},
    ],
  };

  test('nodesOnly builds select + url-test groups and MATCH rule', () {
    final config = ProxyConfigBuilder.build(
      profileConfig: profile,
      mode: ImportMode.nodesOnly,
      selectedNode: 'b',
    );
    final groups = (config['proxy-groups'] as List).cast<Map>();
    final select = groups.firstWhere((g) => g['name'] == 'HOTARU');
    expect(select['type'], 'select');
    expect(select['proxies'], ['b', '自动选择', 'a', 'DIRECT']);
    final auto = groups.firstWhere((g) => g['name'] == '自动选择');
    expect(auto['type'], 'url-test');
    expect(auto['proxies'], ['a', 'b']);
    expect(config['rules'], ['MATCH,HOTARU']);
    // Stored profile must not be mutated by building a runtime config.
    expect(profile.containsKey('proxy-groups'), isFalse);
  });

  test('fullConfig passes through its own groups and rules', () {
    final full = {
      'proxies': (profile['proxies'] as List),
      'proxy-groups': [
        {
          'name': 'Mine',
          'type': 'select',
          'proxies': ['a', 'b'],
        },
      ],
      'rules': ['MATCH,Mine'],
    };
    final config = ProxyConfigBuilder.build(
      profileConfig: full,
      mode: ImportMode.fullConfig,
      selectedNode: 'a',
    );
    expect(config['rules'], ['MATCH,Mine']);
    expect((config['proxy-groups'] as List).length, 1);
  });

  test('unknown selected node is rejected', () {
    expect(
      () => ProxyConfigBuilder.build(
        profileConfig: profile,
        mode: ImportMode.nodesOnly,
        selectedNode: 'ghost',
      ),
      throwsArgumentError,
    );
  });

  group('MihomoApi against a fake loopback core', () {
    late HttpServer server;
    late MihomoApi api;
    String? lastAuth;
    String? lastPutBody;
    String? lastPutPath;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        lastAuth = request.headers.value(HttpHeaders.authorizationHeader);
        final path = request.uri.path;
        if (path == '/version') {
          request.response.write(jsonEncode({'version': 'v-test'}));
        } else if (path == '/proxies' && request.method == 'GET') {
          request.response.write(
            jsonEncode({
              'proxies': {
                'GLOBAL': {
                  'type': 'Selector',
                  'now': 'a',
                  'all': ['a', 'b'],
                },
                'G': {
                  'type': 'Selector',
                  'now': 'a',
                  'all': ['a', 'b'],
                },
                'a': {'type': 'Socks5'},
                'b': {'type': 'Shadowsocks'},
              },
            }),
          );
        } else if (path == '/proxies/G' && request.method == 'PUT') {
          lastPutPath = path;
          lastPutBody = await utf8.decodeStream(request);
          request.response.statusCode = 204;
        } else if (path == '/proxies/a/delay') {
          request.response.write(jsonEncode({'delay': 42}));
        } else if (path == '/proxies/b/delay') {
          request.response.statusCode = 503;
          request.response.write(jsonEncode({'message': 'timeout'}));
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      api = MihomoApi(port: server.port, secret: 's' * 40);
    });

    tearDown(() async {
      api.close();
      await server.close(force: true);
    });

    test('version sends bearer secret and parses', () async {
      expect(await api.version(), 'v-test');
      expect(lastAuth, 'Bearer ${'s' * 40}');
    });

    test('selectNode finds the selector and PUTs the choice', () async {
      expect(await api.selectNode('b'), 'G');
      expect(lastPutPath, '/proxies/G');
      expect(jsonDecode(lastPutBody!), {'name': 'b'});
      expect(await api.selectNode('ghost'), isNull);
    });

    test('delay returns ms and null on failure', () async {
      expect(await api.delay('a'), 42);
      expect(await api.delay('b'), isNull);
    });
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/encoding.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/proxy_definitions.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

void main() {
  test(
    'per-node validation keeps indexes and does not reject unresolved cross-profile dependencies',
    () async {
      final source = <Map<String, dynamic>>[
        {
          'name': 'valid',
          'type': 'http',
          'server': 'proxy.invalid',
          'port': '443',
          'dialer-proxy': 'defined-later',
        },
        {
          'name': 'invalid',
          'type': 'vless',
          'server': '127.0.0.1',
          'port': 443,
          'uuid': 'not-a-uuid',
        },
        {
          'name': 'unsupported',
          'type': 'ssr',
          'server': '127.0.0.1',
          'port': 443,
          'password': 'private-fixture-value',
        },
        {
          'name': 'bad-port',
          'type': 'socks5',
          'server': '127.0.0.1',
          'port': 'invalid',
        },
      ];
      final original = jsonEncode(source);
      final messages = await CoreProxyDefinitions.validate(source);
      expect(messages, hasLength(4));
      expect(messages.first, isEmpty);
      expect(messages[1], contains('invalid_uuid (proxies.1)'));
      expect(messages[2], contains('unsupported_protocol (proxies.2.type)'));
      expect(messages[3], contains('invalid_node_value (proxies.3)'));
      expect(messages.join(), isNot(contains('private-fixture-value')));
      expect(jsonEncode(source), original);
    },
  );

  test(
    'standalone definitions do not replace full configuration graph and DNS validation',
    () async {
      final definitions = <Map<String, dynamic>>[
        {
          'name': 'duplicate',
          'type': 'http',
          'server': 'proxy.invalid',
          'port': 443,
        },
        {
          'name': 'duplicate',
          'type': 'http',
          'server': 'proxy.invalid',
          'port': 443,
        },
      ];
      expect(await CoreProxyDefinitions.validate(definitions), ['', '']);
      final parsed = await ClashProfileImporter().importNodes(definitions);
      final built = await SingBoxConfigBuilder().build(
        CoreProfileSpec(
          nodes: parsed.map((entry) => entry.node!).toList(),
          selectors: [],
          finalOutbound: 'duplicate',
        ),
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(built.json, isNull);
      expect(
        built.issues.map((issue) => issue.code),
        contains('invalid_or_duplicate_tag'),
      );
    },
  );

  test(
    'shared field checks reject missing names, credentials, UUIDs and invalid ports',
    () async {
      final cases = <Map<String, dynamic>>[
        {'name': '', 'type': 'direct'},
        {'name': 'zero', 'type': 'http', 'server': '127.0.0.1', 'port': 0},
        {
          'name': 'auth',
          'type': 'socks5',
          'server': '127.0.0.1',
          'port': 1080,
          'username': 'user',
        },
        {
          'name': 'missing-password',
          'type': 'trojan',
          'server': '127.0.0.1',
          'port': 443,
        },
        {
          'name': 'unknown-options',
          'type': 'http',
          'server': '127.0.0.1',
          'port': 443,
          'plugin': 'must-not-drop',
        },
      ];
      final result = await CoreProxyDefinitions.validate(cases);
      expect(result, everyElement(isNotEmpty));
      expect(result[0], contains('invalid_node_name'));
      expect(result[1], contains('invalid_server'));
      expect(result[2], contains('incomplete_credentials'));
      expect(result[3], contains('missing_password'));
      expect(result[4], contains('unsupported_field'));
      expect(await CoreProxyDefinitions.validate([]), isEmpty);
    },
  );

  test(
    'definition decoding retains a good neighbor when one node is malformed',
    () async {
      final result = await ClashProfileImporter().importNodes([
        {'name': 'good', 'type': 'direct'},
        {'name': 'bad', 'type': 'http', 'server': 5},
      ]);
      expect(result.first.node!.tag, 'good');
      expect(result.first.issues, isEmpty);
      expect(result.last.node, isNull);
      expect(result.last.issues.single.code, 'invalid_node_value');
    },
  );

  test('per-definition batches are bounded before parsing', () async {
    await expectLater(
      ClashProfileImporter().importNodes(
        List.filled(100001, <String, dynamic>{}),
      ),
      throwsA(isA<CoreConfigSizeException>()),
    );
    await expectLater(
      CoreProxyDefinitions.validate([
        {'name': 'x' * (CoreConfigEncoding.maxBytes + 1), 'type': 'direct'},
      ]),
      throwsA(isA<CoreConfigSizeException>()),
    );
  });
}

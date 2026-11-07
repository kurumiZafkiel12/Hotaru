import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

const _fixture = '''
proxies:
  - {name: HTTP, type: http, server: 127.0.0.1, port: 14443, username: test, password: fixture}
  - {name: SOCKS, type: socks5, server: 127.0.0.1, port: 14443, udp: false}
  - {name: SS, type: ss, server: 127.0.0.1, port: 14443, cipher: aes-128-gcm, password: fixture}
  - name: VMess
    type: vmess
    server: fixture.example.com
    port: 14443
    uuid: f0db417e-1460-4a2b-b37f-e62a1ab9d91c
    cipher: auto
    alterId: 0
    tls: true
    servername: fixture.example.com
    network: ws
    ws-opts: {path: /fixture, headers: {Host: fixture.example.com}}
  - name: VLESS
    type: vless
    server: 127.0.0.1
    port: 14443
    uuid: f0db417e-1460-4a2b-b37f-e62a1ab9d91c
    tls: true
    network: grpc
    grpc-opts: {grpc-service-name: fixture}
  - {name: Trojan, type: trojan, server: 127.0.0.1, port: 14443, password: fixture}
  - {name: HY2, type: hysteria2, server: 127.0.0.1, port: 14443, password: fixture, obfs: salamander, obfs-password: fixture, up: 10, down: 20}
  - {name: TUIC, type: tuic, server: 127.0.0.1, port: 14443, uuid: f0db417e-1460-4a2b-b37f-e62a1ab9d91c, password: fixture, congestion-controller: bbr, udp-relay-mode: native}
proxy-groups:
  - {name: Selected, type: select, proxies: [HTTP, SOCKS, SS, VMess, VLESS, Trojan, HY2, TUIC, DIRECT]}
  - {name: Automatic, type: url-test, proxies: [HTTP, SOCKS], url: 'https://example.com/check', interval: 180, tolerance: 25}
rules:
  - DOMAIN,example.com,Selected
  - DOMAIN-SUFFIX,example.org,Automatic
  - DOMAIN-KEYWORD,blocked,REJECT
  - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve
  - IP-CIDR6,2001:db8::/32,DIRECT,no-resolve
  - MATCH,Selected
''';

void main() {
  final importer = ClashProfileImporter();
  final builder = SingBoxConfigBuilder();
  const listeners = CoreListenerSpec(
    mixedPort: 17890,
    controllerPort: 19090,
    secret: 'fixture-secret',
  );

  test(
    'imports common protocols and ordered rules without Mihomo models',
    () async {
      final imported = await importer.import(_fixture);
      expect(imported.issues, isEmpty);
      final profile = imported.profile!;
      expect(profile.nodes.length, 9);
      expect(
        profile.nodes
            .singleWhere((node) => node.tag == 'VMess')
            .transport!
            .headers,
        {'Host': 'fixture.example.com'},
      );
      expect(
        profile.nodes.singleWhere((node) => node.tag == 'SOCKS').tcpOnly,
        isTrue,
      );
      expect(
        profile.nodes.singleWhere((node) => node.tag == 'Trojan').tls,
        isNotNull,
      );
      expect(profile.rules[2].action, CoreRuleAction.reject);
      final built = await builder.build(profile, listeners);
      expect(built.issues, isEmpty);
      final config = jsonDecode(built.json!) as Map<String, dynamic>;
      expect(
        config['outbounds'].singleWhere((node) => node['tag'] == 'HY2')['obfs'],
        {'type': 'salamander', 'password': 'fixture'},
      );
      expect(config['outbounds'].last['interval'], '180s');
      final profileRules = (config['route']['rules'] as List)
          .where((dynamic rule) => rule['clash_mode'] == null)
          .toList();
      expect(profileRules[2]['action'], 'reject');
      expect(config['route']['final'], 'Selected');
    },
  );

  test(
    'preserves Reality fields rather than treating it as ordinary TLS',
    () async {
      final source = jsonEncode({
        'proxies': [
          {
            'name': 'Reality',
            'type': 'vless',
            'server': '127.0.0.1',
            'port': 443,
            'uuid': 'f0db417e-1460-4a2b-b37f-e62a1ab9d91c',
            'tls': true,
            'flow': 'xtls-rprx-vision',
            'client-fingerprint': 'chrome',
            'reality-opts': {
              'public-key': base64Url
                  .encode(List.generate(32, (index) => index + 1))
                  .replaceAll('=', ''),
              'short-id': '01234567',
            },
          },
        ],
        'rules': ['MATCH,Reality'],
      });
      final imported = await importer.import(source);
      expect(imported.issues, isEmpty);
      final built = await builder.build(imported.profile!, listeners);
      final node = (jsonDecode(built.json!)['outbounds'] as List).singleWhere(
        (dynamic node) => node['tag'] == 'Reality',
      );
      expect(node['flow'], 'xtls-rprx-vision');
      expect(node['tls']['reality']['short_id'], '01234567');
      expect(node['tls']['utls']['fingerprint'], 'chrome');
    },
  );

  test('records non-equivalent group conversions as warnings', () async {
    final imported = await importer.import('''
proxies: []
proxy-groups:
  - {name: Balanced, type: load-balance, proxies: [DIRECT]}
  - {name: Failover, type: fallback, proxies: [DIRECT]}
rules: ["MATCH,Balanced"]
''');
    expect(imported.profile, isNotNull);
    expect(imported.issues.map((issue) => issue.code), [
      'load_balance_to_selector',
      'fallback_to_urltest',
    ]);
    expect(
      imported.issues.every(
        (issue) => issue.severity == CoreConfigIssueSeverity.warning,
      ),
      isTrue,
    );
    expect(
      imported.profile!.selectors.last.strategy,
      CoreGroupStrategy.urltest,
    );
  });

  test(
    'rejects unconverted provider and DNS sections instead of ignoring them',
    () async {
      final imported = await importer.import('''
proxy-providers: {remote: {url: 'https://example.com/private-subscription'}}
rule-providers: {remote: {url: 'https://example.com/rules'}}
dns: {enable: true}
rules: ["MATCH,DIRECT"]
''');
      expect(imported.profile, isNull);
      expect(
        imported.issues.map((issue) => issue.code),
        containsAll([
          'provider_expansion_required',
          'rule_provider_conversion_required',
          'invalid_dns_value',
        ]),
      );
      expect(
        imported.issues.map((issue) => issue.path).join(),
        isNot(contains('private-subscription')),
      );
    },
  );

  test(
    'unsupported protocols and encrypted VLESS cannot silently disappear',
    () async {
      final imported = await importer.import('''
proxies:
  - {name: Legacy, type: ssr, password: secret-should-not-appear}
  - {name: VLESS, type: vless, uuid: bad, encryption: mlkem768x25519plus}
rules: ["MATCH,DIRECT"]
''');
      expect(imported.profile, isNull);
      expect(
        imported.issues.map((issue) => issue.code),
        containsAll(['unsupported_protocol', 'unsupported_vless_encryption']),
      );
      expect(
        imported.issues.map((issue) => issue.path).join(),
        isNot(contains('secret-should-not-appear')),
      );
    },
  );

  test(
    'unknown protocol options block import even if base proxy is supported',
    () async {
      final imported = await importer.import('''
proxies:
  - {name: SS, type: ss, server: 127.0.0.1, port: 443, cipher: aes-128-gcm, password: fixture, plugin: obfs}
rules: ["MATCH,SS"]
''');
      expect(imported.profile, isNull);
      expect(imported.issues.single.path, 'proxies.0.plugin');
    },
  );

  test('does not invent a final route or discard rules after MATCH', () async {
    for (final source in [
      'rules: ["DOMAIN,example.com,DIRECT"]',
      'rules: ["MATCH,DIRECT", "DOMAIN,example.com,DIRECT"]',
      'rules: ["GEOIP,CN,DIRECT", "MATCH,DIRECT"]',
    ]) {
      final imported = await importer.import(source);
      expect(imported.profile, isNull);
      expect(imported.issues, isNotEmpty);
    }
  });

  test(
    'reject and drop are actual route actions, including terminal MATCH',
    () async {
      final imported = await importer.import('''
rules: ["DOMAIN,example.com,REJECT", "MATCH,REJECT-DROP"]
''');
      expect(imported.issues, isEmpty);
      final built = await builder.build(imported.profile!, listeners);
      final rules = (jsonDecode(built.json!)['route']['rules'] as List)
          .where((dynamic rule) => rule['clash_mode'] == null)
          .toList();
      expect(rules.last, {'action': 'reject', 'method': 'drop'});
      expect(rules.first.containsKey('outbound'), isFalse);
    },
  );

  test(
    'app-owned bindings are disclosed and source secrets are not copied',
    () async {
      final imported = await importer.import('''
mixed-port: 7890
external-controller: 0.0.0.0:9090
secret: source-secret
rules: ["MATCH,DIRECT"]
''');
      expect(imported.issues.length, 3);
      final built = await builder.build(imported.profile!, listeners);
      expect(built.json, isNot(contains('source-secret')));
      expect(built.json, isNot(contains('0.0.0.0')));
    },
  );

  test('malformed YAML and field types produce structured errors', () async {
    for (final source in [
      '[unclosed',
      'proxies: 42',
      'rules: [123]',
      'proxies: [{name: p, type: http, server: true, port: 443}]\nrules: ["MATCH,p"]',
      'proxies: [{name: p, type: socks5, server: localhost, port: 443, udp: "false"}]\nrules: ["MATCH,p"]',
    ]) {
      final imported = await importer.import(source);
      expect(imported.profile, isNull);
      expect(imported.issues, isNotEmpty);
    }
  });

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  test(
    'imported fixture compiles and passes the pinned upstream validator',
    () async {
      final imported = await importer.import(_fixture);
      final built = await builder.build(imported.profile!, listeners);
      expect(built.json, isNotNull);
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-import-check-',
      );
      try {
        final file = await File(
          '${directory.path}/config.json',
        ).writeAsString(built.json!);
        final result = await Process.run(binary!, ['check', '-c', file.path]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX to validate against upstream 1.14.4'
        : false,
  );
}

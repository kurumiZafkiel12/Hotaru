import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/encoding.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/share_links.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

const _uuid = 'f0db417e-1460-4a2b-b37f-e62a1ab9d91c';
String _b64(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

void main() {
  final vmess =
      'vmess://${_b64(jsonEncode({'v': '2', 'ps': 'VMess', 'add': '127.0.0.1', 'port': '443', 'id': _uuid, 'aid': '0', 'scy': 'auto', 'net': 'ws', 'path': '/socket', 'host': 'example.org', 'tls': 'tls', 'sni': 'example.org'}))}';
  final fixtures = [
    'http://user:p%40ss%3Aword@127.0.0.1:8080#HTTP',
    'https://127.0.0.1:443?sni=example.org#HTTPS',
    'socks5://u:p@[::1]:1080#SOCKS',
    'ss://${_b64('aes-128-gcm:fixture')}@127.0.0.1:8388#SS',
    vmess,
    'vless://$_uuid@127.0.0.1:443?encryption=none&security=tls&type=grpc&serviceName=fixture&sni=example.org#VLESS',
    'trojan://p%40ss@127.0.0.1:443?sni=example.org#Trojan',
    'hy2://fixture@127.0.0.1:443?sni=example.org&obfs=salamander&obfs-password=fixture-obfs#HY2',
    'tuic://$_uuid:fixture@127.0.0.1:443?congestion_control=cubic&udp_relay_mode=native&alpn=h3#TUIC',
    'vless://$_uuid@127.0.0.1:443?security=reality&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=0123#Reality',
  ];

  test(
    'common link families retain credentials, TLS, transport and node order',
    () async {
      final result = await CoreShareLinks.decode(fixtures.join('\r\n'));
      expect(result.issues, isEmpty);
      expect(result.nodes.map((node) => node['name']), [
        'HTTP',
        'HTTPS',
        'SOCKS',
        'SS',
        'VMess',
        'VLESS',
        'Trojan',
        'HY2',
        'TUIC',
        'Reality',
      ]);
      expect(result.nodes.first['username'], 'user');
      expect(result.nodes.first['password'], 'p@ss:word');
      expect(result.nodes[1]['tls'], isTrue);
      expect(result.nodes[2]['server'], '::1');
      expect(result.nodes[3]['password'], 'fixture');
      expect(result.nodes[4]['ws-opts'], {
        'path': '/socket',
        'headers': {'Host': 'example.org'},
      });
      expect(result.nodes[5]['grpc-opts'], {'grpc-service-name': 'fixture'});
      expect(result.nodes[6]['password'], 'p@ss');
      expect(result.nodes[7]['obfs-password'], 'fixture-obfs');
      expect(result.nodes[8]['uuid'], _uuid);
      expect(result.nodes.last['reality-opts']['short-id'], '0123');
      final imported = await CoreShareLinks.import(fixtures.join('\n'));
      expect(imported.issues, isEmpty);
      expect(imported.profile!.nodes, hasLength(10));
      final built = await SingBoxConfigBuilder().build(
        imported.profile!,
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(built.issues, isEmpty);
    },
  );

  test(
    'SIP002, legacy SS, Unicode fragments and comma names are preserved',
    () async {
      final links = [
        'ss://${_b64('aes-128-gcm:password@127.0.0.1:8388')}#%E6%97%A5%E6%9C%AC%2C%20A',
        'ss://aes-128-gcm:p%3Ass%40word@127.0.0.1:8389#Hotaru%20Imported',
      ];
      final decoded = await CoreShareLinks.decode(links.join('\n'));
      expect(decoded.issues, isEmpty);
      expect(decoded.nodes.first['name'], '日本, A');
      expect(decoded.nodes.last['password'], 'p:ss@word');
      final imported = await CoreShareLinks.import(links.join('\n'));
      expect(imported.issues, isEmpty);
      expect(imported.profile!.finalOutbound, 'Hotaru Imported (1)');
      expect(imported.profile!.selectors.single.members, [
        '日本, A',
        'Hotaru Imported',
      ]);
    },
  );

  test(
    'whole base64 subscriptions and per-input expansions keep their boundaries',
    () async {
      final source = fixtures.take(2).join('\n');
      final result = await CoreShareLinks.decode(_b64(source));
      expect(result.issues, isEmpty);
      expect(result.nodes, hasLength(2));
      final batches = await CoreShareLinks.decodeMany([
        fixtures.first,
        _b64(source),
      ]);
      expect(batches.map((batch) => batch.nodes.length), [1, 2]);
      expect(
        (await CoreShareLinks.decode('# comment\n${fixtures.first}')).nodes,
        hasLength(1),
      );
    },
  );

  test(
    'percent escapes in credentials are interpreted exactly once in each SS encoding',
    () async {
      final links = [
        'ss://${_b64('aes-128-gcm:literal%40%password@127.0.0.1:8388')}',
        'ss://${_b64('aes-128-gcm:literal%40%password')}@127.0.0.1:8388',
        'ss://aes-128-gcm:literal%2540%25password@127.0.0.1:8388',
      ];
      final result = await CoreShareLinks.decode(links.join('\n'));
      expect(result.issues, isEmpty);
      expect(
        result.nodes.map((node) => node['password']),
        everyElement('literal%40%password'),
      );
    },
  );

  test(
    'unsupported options and malformed input produce no partial imports or credential-bearing diagnostics',
    () async {
      for (final bad in [
        'ss://${_b64('aes-128-gcm:private-password')}@127.0.0.1:8388?plugin=not-supported',
        'vless://$_uuid@127.0.0.1:443?security=tls&type=httpupgrade',
        'trojan://private-password@127.0.0.1:443?pinSHA256=not-supported',
        'hy2://private-password@127.0.0.1:443?insecure=2',
        'socks5://127.0.0.1:0',
        'socks5://127.0.0.1:65536',
        'http://127.0.0.1:8080/custom-path',
        'vless://$_uuid@127.0.0.1:443?security=tls&sni=a&sni=b',
        'ssr://private-password',
        'vmess://not-base64!',
        'vmess://${_b64('{"ps":123}')} ',
        'vmess://${_b64('[]')}',
        'vmess://${_b64('{"add":"localhost","port":443,"id":"$_uuid","aid":true}')}',
      ]) {
        final decoded = await CoreShareLinks.decode('${fixtures.first}\n$bad');
        expect(decoded.nodes, isEmpty, reason: bad.split('://').first);
        expect(decoded.issues, hasLength(1));
        expect(decoded.issues.single.path, startsWith('lines.1'));
        expect(decoded.issues.single.code, isNot(contains('private-password')));
        expect(
          (await CoreShareLinks.import('${fixtures.first}\n$bad')).profile,
          isNull,
        );
      }
    },
  );

  test(
    'source, line and multi-input budgets fail before unbounded expansion',
    () async {
      expect(
        (await CoreShareLinks.decode('')).issues.single.code,
        'empty_share_links',
      );
      expect(
        (await CoreShareLinks.decode(
          'x' * (CoreConfigEncoding.maxBytes + 1),
        )).issues.single.code,
        'share_source_too_large',
      );
      expect(
        (await CoreShareLinks.decode('http://localhost#${'x' * 65537}')).nodes,
        isEmpty,
      );
      expect(
        (await CoreShareLinks.decode('http://localhost#${'萤' * 24000}')).nodes,
        isEmpty,
      );
      await expectLater(
        CoreShareLinks.decodeMany(List.filled(100001, '')),
        throwsA(isA<CoreConfigSizeException>()),
      );
      await expectLater(
        CoreShareLinks.decodeMany([
          'x' * (CoreConfigEncoding.maxBytes ~/ 2 + 1),
          'x' * (CoreConfigEncoding.maxBytes ~/ 2 + 1),
        ]),
        throwsA(isA<CoreConfigSizeException>()),
      );
    },
  );

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  test(
    'pinned engine checks the generated configuration for all supported link fixtures',
    () async {
      final imported = await CoreShareLinks.import(fixtures.join('\n'));
      expect(imported.issues, isEmpty);
      final built = await SingBoxConfigBuilder().build(
        imported.profile!,
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(built.issues, isEmpty);
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-share-check-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/config.json',
      ).writeAsString(built.json!);
      final result = await Process.run(binary!, ['check', '-c', file.path]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX to a pinned engine'
        : false,
  );
}

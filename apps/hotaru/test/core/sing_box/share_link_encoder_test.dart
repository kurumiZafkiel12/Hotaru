import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/encoding.dart';
import 'package:hotaru/core/config/node_definition.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/share_link_encoder.dart';
import 'package:hotaru/core/config/share_links.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

const uuid = '00000000-0000-4000-8000-000000000001';

void main() {
  final links = [
    'http://u%3A%25:p%40%25@127.0.0.1:8080#%E6%97%A5%E6%9C%AC%25',
    'https://127.0.0.1:443?sni=example.invalid&alpn=h2&insecure=1#HTTPS',
    'socks5://u:p@[::1]:1080#SOCKS',
    'ss://${base64Url.encode(utf8.encode('aes-128-gcm:literal%40@pass'))}@127.0.0.1:443#SS',
    'vmess://${base64Url.encode(utf8.encode(jsonEncode({'v': '2', 'ps': 'VMess %40', 'add': '127.0.0.1', 'port': 443, 'id': uuid, 'net': 'ws', 'path': '/ws', 'host': 'example.invalid', 'tls': 'tls', 'sni': 'example.invalid'})))}',
    'vless://$uuid@127.0.0.1:443?security=reality&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=ab12#Reality',
    'trojan://p%3A%25@127.0.0.1:443?type=grpc&serviceName=service#Trojan',
    'hy2://p%40ss@127.0.0.1:443?obfs=salamander&obfs-password=obfs#HY2',
    'tuic://$uuid:p%3A%25@127.0.0.1:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3#TUIC',
  ];
  test(
    'shareable definitions retain their compiled behavior through export and reimport',
    () async {
      final input = await CoreShareLinks.decode(links.join('\n'));
      expect(input.issues, isEmpty);
      final original = jsonEncode(input.nodes);
      final output = await CoreShareLinkEncoder.encode(input.nodes);
      expect(output, hasLength(links.length));
      expect(
        output.every((link) => link.isNotEmpty),
        isTrue,
        reason: '$output',
      );
      expect(jsonEncode(input.nodes), original);
      final before = await CoreShareLinks.import(links.join('\n'));
      final after = await CoreShareLinks.import(output.join('\n'));
      expect(after.issues, isEmpty);
      const listeners = CoreListenerSpec(
        mixedPort: 17890,
        controllerPort: 19090,
        secret: 'fixture',
      );
      final first = await SingBoxConfigBuilder().build(
        before.profile!,
        listeners,
      );
      final second = await SingBoxConfigBuilder().build(
        after.profile!,
        listeners,
      );
      expect(jsonDecode(second.json!), jsonDecode(first.json!));
    },
  );

  test(
    'unrepresentable settings and invalid nodes preserve their indexes without lossy links',
    () async {
      final input = (await CoreShareLinks.decode(links.join('\n'))).nodes;
      final definitions = [
        {'name': 'direct', 'type': 'direct'},
        {...input.first, 'dialer-proxy': 'hop'},
        input.first,
        {
          ...input[4],
          'ws-opts': {
            'path': '/ws',
            'headers': {
              'Host': 'example.invalid',
              'Authorization': 'private-fixture',
            },
          },
        },
        {...input[7], 'up': 10},
        {...input[1], 'udp': false},
        {...input.first, 'port': 0},
        {...input.first, 'server': 'bad/host'},
        {...input.first, 'unknown': 'private-fixture'},
      ];
      final output = await CoreShareLinkEncoder.encode(definitions);
      expect(output, hasLength(definitions.length));
      expect(output[2], isNotEmpty);
      expect([
        for (var i = 0; i < output.length; i++)
          if (i != 2) output[i],
      ], everyElement(isEmpty));
      expect(output.join(), isNot(contains('private-fixture')));
    },
  );

  test(
    'raw URI delimiters, percent names and passwords remain literal exactly once',
    () async {
      final input = CoreNodeDefinition.fromNode(
        const CoreNodeSpec(
          tag: '日本, literal%40% /#?',
          protocol: CoreNodeProtocol.http,
          server: '::1',
          port: 8080,
          username: 'u:%@',
          password: 'p%40%:/@#?',
        ),
      );
      final output = await CoreShareLinkEncoder.encode([input]);
      expect(output.single, isNotEmpty);
      final result = await CoreShareLinks.decode(output.single);
      expect(result.issues, isEmpty);
      expect(result.nodes.single, input);
    },
  );

  test(
    'export bounds input before encoding and handles empty selections',
    () async {
      expect(await CoreShareLinkEncoder.encode([]), isEmpty);
      await expectLater(
        CoreShareLinkEncoder.encode(List.filled(100001, {})),
        throwsA(isA<CoreConfigSizeException>()),
      );
      await expectLater(
        CoreShareLinkEncoder.encode([
          {'name': 'x' * (CoreConfigEncoding.maxBytes + 1)},
        ]),
        throwsA(isA<CoreConfigSizeException>()),
      );
    },
  );
}

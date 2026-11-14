import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/node_definition.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

void main() {
  final nodes = <CoreNodeSpec>[
    const CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
    const CoreNodeSpec(
      tag: 'http',
      protocol: CoreNodeProtocol.http,
      server: '127.0.0.1',
      port: 443,
      username: 'u:%',
      password: 'p:%',
      detour: 'socks',
      tcpOnly: true,
    ),
    const CoreNodeSpec(
      tag: 'socks',
      protocol: CoreNodeProtocol.socks,
      server: '::1',
      port: 1080,
      username: 'user',
      password: 'pass',
    ),
    const CoreNodeSpec(
      tag: 'ss',
      protocol: CoreNodeProtocol.shadowsocks,
      server: '127.0.0.1',
      port: 443,
      cipher: 'aes-128-gcm',
      password: 'pass',
    ),
    CoreNodeSpec(
      tag: 'vmess',
      protocol: CoreNodeProtocol.vmess,
      server: '127.0.0.1',
      port: 443,
      uuid: '00000000-0000-4000-8000-000000000001',
      cipher: 'auto',
      alterId: 0,
      tls: CoreTlsSpec(
        serverName: 'example.invalid',
        alpn: ['h2'],
        insecure: true,
      ),
      transport: CoreTransportSpec(
        kind: CoreTransportKind.ws,
        path: '/socket',
        headers: {'Host': 'example.invalid'},
      ),
    ),
    CoreNodeSpec(
      tag: 'vless',
      protocol: CoreNodeProtocol.vless,
      server: '127.0.0.1',
      port: 443,
      uuid: '00000000-0000-4000-8000-000000000001',
      flow: 'xtls-rprx-vision',
      tls: CoreTlsSpec(
        serverName: 'example.invalid',
        fingerprint: 'chrome',
        realityPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        realityShortId: 'ab12',
      ),
    ),
    CoreNodeSpec(
      tag: 'trojan',
      protocol: CoreNodeProtocol.trojan,
      server: '127.0.0.1',
      port: 443,
      password: 'pass',
      tls: CoreTlsSpec(),
      transport: CoreTransportSpec(
        kind: CoreTransportKind.grpc,
        serviceName: 'service',
      ),
    ),
    CoreNodeSpec(
      tag: 'hy2',
      protocol: CoreNodeProtocol.hysteria2,
      server: '127.0.0.1',
      port: 443,
      password: 'pass',
      tls: CoreTlsSpec(),
      obfsPassword: 'obfs',
      upMbps: 10,
      downMbps: 20,
    ),
    CoreNodeSpec(
      tag: 'tuic',
      protocol: CoreNodeProtocol.tuic,
      server: '127.0.0.1',
      port: 443,
      uuid: '00000000-0000-4000-8000-000000000001',
      password: 'pass',
      tls: CoreTlsSpec(alpn: ['h3']),
      congestionControl: 'bbr',
      udpRelayMode: 'native',
    ),
  ];
  CoreProfileSpec profile(List<CoreNodeSpec> entries) => CoreProfileSpec(
    nodes: entries,
    selectors: [],
    finalOutbound: entries.last.tag,
  );
  const listeners = CoreListenerSpec(
    mixedPort: 17890,
    controllerPort: 19090,
    secret: 'fixture',
  );

  test(
    'editor definitions round trip every supported protocol without changing compiled options',
    () async {
      for (final node in nodes) {
        final input = [if (node.detour != null) nodes[2], node];
        final original = await SingBoxConfigBuilder().build(
          profile(input),
          listeners,
        );
        expect(
          original.json,
          isNotNull,
          reason: '${node.tag}: ${original.issues.map((issue) => issue.code)}',
        );
        final parsed = await ClashProfileImporter().importNodes(
          input.map(CoreNodeDefinition.fromNode).toList(),
        );
        expect(
          parsed.expand((entry) => entry.issues),
          isEmpty,
          reason: node.tag,
        );
        final restored = await SingBoxConfigBuilder().build(
          profile(parsed.map((entry) => entry.node!).toList()),
          listeners,
        );
        expect(
          jsonDecode(restored.json!),
          jsonDecode(original.json!),
          reason: node.tag,
        );
      }
    },
  );

  test(
    'definitions detach nested collections and resolve nodes rather than group names',
    () async {
      final input = profile(nodes);
      final found = await CoreNodeDefinition.find(input, 'vmess');
      expect(found!['name'], 'vmess');
      (found['alpn'] as List).clear();
      ((found['ws-opts'] as Map)['headers'] as Map)['Host'] =
          'modified.invalid';
      expect(nodes[4].tls!.alpn, ['h2']);
      expect(nodes[4].transport!.headers, {'Host': 'example.invalid'});
      expect(await CoreNodeDefinition.find(input, 'missing'), isNull);
    },
  );
}

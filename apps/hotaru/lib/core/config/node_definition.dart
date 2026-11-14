import 'dart:isolate';

import 'profile.dart';

final class CoreNodeDefinition {
  static Future<Map<String, dynamic>?> find(
    CoreProfileSpec profile,
    String name,
  ) => _find(profile.nodes, name);

  static Future<Map<String, dynamic>?> _find(
    List<CoreNodeSpec> nodes,
    String name,
  ) => Isolate.run(() {
    for (final node in nodes) {
      if (node.tag == name) return fromNode(node);
    }
    return null;
  });

  static Map<String, dynamic> fromNode(CoreNodeSpec node) {
    final tls = node.tls;
    final transport = node.transport;
    return {
      'name': node.tag,
      'type': switch (node.protocol) {
        CoreNodeProtocol.direct => 'direct',
        CoreNodeProtocol.http => 'http',
        CoreNodeProtocol.socks => 'socks5',
        CoreNodeProtocol.shadowsocks => 'ss',
        CoreNodeProtocol.vmess => 'vmess',
        CoreNodeProtocol.vless => 'vless',
        CoreNodeProtocol.trojan => 'trojan',
        CoreNodeProtocol.hysteria2 => 'hysteria2',
        CoreNodeProtocol.tuic => 'tuic',
      },
      'server': ?node.server,
      'port': ?node.port,
      'dialer-proxy': ?node.detour,
      'username': ?node.username,
      'password': ?node.password,
      'uuid': ?node.uuid,
      'cipher': ?node.cipher,
      'alterId': ?node.alterId,
      'flow': ?node.flow,
      'congestion-controller': ?node.congestionControl,
      'udp-relay-mode': ?node.udpRelayMode,
      if (node.obfsPassword != null) 'obfs': 'salamander',
      'obfs-password': ?node.obfsPassword,
      'up': ?node.upMbps,
      'down': ?node.downMbps,
      if (node.tcpOnly) 'udp': false,
      if (tls != null) ...{
        'tls': true,
        'servername': ?tls.serverName,
        'skip-cert-verify': tls.insecure,
        if (tls.alpn.isNotEmpty) 'alpn': tls.alpn.toList(),
        'client-fingerprint': ?tls.fingerprint,
        if (tls.realityPublicKey != null)
          'reality-opts': {
            'public-key': tls.realityPublicKey,
            'short-id': ?tls.realityShortId,
          },
      } else if (const [
        CoreNodeProtocol.trojan,
        CoreNodeProtocol.hysteria2,
        CoreNodeProtocol.tuic,
      ].contains(node.protocol))
        'tls': false,
      if (transport != null) ...{
        'network': transport.kind.name,
        if (transport.kind == CoreTransportKind.ws)
          'ws-opts': {
            'path': ?transport.path,
            if (transport.headers.isNotEmpty)
              'headers': Map<String, String>.of(transport.headers),
          },
        if (transport.kind == CoreTransportKind.grpc)
          'grpc-opts': {'grpc-service-name': ?transport.serviceName},
      },
    };
  }
}

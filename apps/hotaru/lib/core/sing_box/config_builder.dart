import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import '../config/profile.dart';
import '../config/encoding.dart';
import '../config/ip_prefix.dart';
import '../config/probe_listener.dart';
import 'dns_config.dart';

final class SingBoxConfigBuilder {
  Future<CoreConfigBuildResult> build(
    CoreProfileSpec profile,
    CoreListenerSpec listeners,
  ) {
    return Isolate.run(() => _build(profile, listeners));
  }

  static CoreConfigBuildResult _build(
    CoreProfileSpec profile,
    CoreListenerSpec listeners,
  ) {
    final issues = <CoreConfigIssue>[];
    final tags = <String>{};
    void tag(String value, String path) {
      if (value.isEmpty || !tags.add(value)) {
        issues.add(CoreConfigIssue('invalid_or_duplicate_tag', path));
      }
    }

    for (final node in profile.nodes) {
      tag(node.tag, 'nodes.${node.tag}');
      final options = <String, Object?>{
        'username': node.username,
        'password': node.password,
        'uuid': node.uuid,
        'cipher': node.cipher,
        'alterId': node.alterId,
        'flow': node.flow,
        'tls': node.tls,
        'transport': node.transport,
        'congestionControl': node.congestionControl,
        'udpRelayMode': node.udpRelayMode,
        'obfsPassword': node.obfsPassword,
        'upMbps': node.upMbps,
        'downMbps': node.downMbps,
      };
      final allowed = switch (node.protocol) {
        CoreNodeProtocol.direct => <String>{},
        CoreNodeProtocol.http => {'username', 'password', 'tls'},
        CoreNodeProtocol.socks => {'username', 'password'},
        CoreNodeProtocol.shadowsocks => {'password', 'cipher'},
        CoreNodeProtocol.vmess => {
          'uuid',
          'cipher',
          'alterId',
          'tls',
          'transport',
        },
        CoreNodeProtocol.vless => {'uuid', 'flow', 'tls', 'transport'},
        CoreNodeProtocol.trojan => {'password', 'tls', 'transport'},
        CoreNodeProtocol.hysteria2 => {
          'password',
          'tls',
          'obfsPassword',
          'upMbps',
          'downMbps',
        },
        CoreNodeProtocol.tuic => {
          'uuid',
          'password',
          'tls',
          'congestionControl',
          'udpRelayMode',
        },
      };
      for (final option in options.entries) {
        if (option.value != null && !allowed.contains(option.key)) {
          issues.add(
            CoreConfigIssue(
              'unsupported_protocol_option',
              'nodes.${node.tag}.${option.key}',
            ),
          );
        }
      }
      if (node.tls?.realityPublicKey != null &&
          node.protocol != CoreNodeProtocol.vless) {
        issues.add(CoreConfigIssue('unsupported_reality', 'nodes.${node.tag}'));
      }
      if (node.transport case final transport?) {
        if (transport.kind == CoreTransportKind.grpc &&
                (transport.path != null || transport.headers.isNotEmpty) ||
            transport.kind == CoreTransportKind.ws &&
                transport.serviceName != null) {
          issues.add(
            CoreConfigIssue(
              'incompatible_transport_options',
              'nodes.${node.tag}',
            ),
          );
        }
      }
      if (node.protocol == CoreNodeProtocol.direct) {
        if (node.server != null ||
            node.port != null ||
            node.username != null ||
            node.password != null ||
            node.tls != null ||
            node.transport != null ||
            node.detour != null) {
          issues.add(
            CoreConfigIssue('direct_has_proxy_fields', 'nodes.${node.tag}'),
          );
        }
      } else if (node.server == null ||
          node.server!.trim().isEmpty ||
          node.port == null ||
          node.port! < 1 ||
          node.port! > 65535) {
        issues.add(CoreConfigIssue('invalid_server', 'nodes.${node.tag}'));
      }
      if (const [
            CoreNodeProtocol.http,
            CoreNodeProtocol.socks,
          ].contains(node.protocol) &&
          (node.username == null) != (node.password == null)) {
        issues.add(
          CoreConfigIssue('incomplete_credentials', 'nodes.${node.tag}'),
        );
      }
      if (const [
            CoreNodeProtocol.vless,
            CoreNodeProtocol.vmess,
            CoreNodeProtocol.tuic,
          ].contains(node.protocol) &&
          (node.uuid == null ||
              !RegExp(
                r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
              ).hasMatch(node.uuid!))) {
        issues.add(CoreConfigIssue('invalid_uuid', 'nodes.${node.tag}'));
      }
      if (const [
            CoreNodeProtocol.shadowsocks,
            CoreNodeProtocol.trojan,
            CoreNodeProtocol.hysteria2,
            CoreNodeProtocol.tuic,
          ].contains(node.protocol) &&
          (node.password == null || node.password!.isEmpty)) {
        issues.add(CoreConfigIssue('missing_password', 'nodes.${node.tag}'));
      }
      if (node.protocol == CoreNodeProtocol.shadowsocks &&
          (node.cipher == null || node.cipher!.isEmpty)) {
        issues.add(CoreConfigIssue('missing_cipher', 'nodes.${node.tag}'));
      }
      if (const [
            CoreNodeProtocol.hysteria2,
            CoreNodeProtocol.tuic,
          ].contains(node.protocol) &&
          node.tls == null) {
        issues.add(CoreConfigIssue('tls_required', 'nodes.${node.tag}'));
      }
      if (node.transport != null &&
          !const [
            CoreNodeProtocol.vmess,
            CoreNodeProtocol.vless,
            CoreNodeProtocol.trojan,
          ].contains(node.protocol)) {
        issues.add(
          CoreConfigIssue('unsupported_transport', 'nodes.${node.tag}'),
        );
      }
      if (node.tls != null &&
          const [
            CoreNodeProtocol.socks,
            CoreNodeProtocol.shadowsocks,
          ].contains(node.protocol)) {
        issues.add(CoreConfigIssue('unsupported_tls', 'nodes.${node.tag}'));
      }
    }
    for (final selector in profile.selectors) {
      tag(selector.tag, 'selectors.${selector.tag}');
    }
    if (!tags.contains(profile.finalOutbound)) {
      issues.add(
        const CoreConfigIssue('unknown_final_outbound', 'finalOutbound'),
      );
    }
    final groups = {for (final group in profile.selectors) group.tag: group};
    for (final selector in profile.selectors) {
      if (selector.members.isEmpty ||
          selector.members.toSet().length != selector.members.length) {
        issues.add(
          CoreConfigIssue('invalid_members', 'selectors.${selector.tag}'),
        );
      }
      for (final member in selector.members) {
        if (!tags.contains(member)) {
          issues.add(
            CoreConfigIssue(
              'unknown_member',
              'selectors.${selector.tag}.$member',
            ),
          );
        }
      }
      if (selector.selected != null &&
          !selector.members.contains(selector.selected)) {
        issues.add(
          CoreConfigIssue('invalid_selection', 'selectors.${selector.tag}'),
        );
      }
      if (selector.strategy == CoreGroupStrategy.urltest &&
          (Uri.tryParse(selector.testUrl)?.scheme != 'https' ||
              selector.interval.inSeconds < 1 ||
              selector.tolerance < 0 ||
              selector.selected != null)) {
        issues.add(
          CoreConfigIssue('invalid_urltest', 'selectors.${selector.tag}'),
        );
      }
    }
    for (var index = 0; index < profile.rules.length; index++) {
      final rule = profile.rules[index];
      if (rule.kind == CoreRuleKind.ipCidr) {
        if (!rule.noResolve) {
          issues.add(
            CoreConfigIssue('ip_rule_resolution_not_migrated', 'rules.$index'),
          );
        }
        if (CoreIpPrefix.parse(rule.value) == null) {
          issues.add(CoreConfigIssue('invalid_ip_prefix', 'rules.$index'));
        }
      } else if (rule.noResolve) {
        issues.add(CoreConfigIssue('unexpected_no_resolve', 'rules.$index'));
      }
      if (rule.action == CoreRuleAction.route &&
              !tags.contains(rule.outbound) ||
          rule.action != CoreRuleAction.route && rule.outbound != null ||
          rule.kind != CoreRuleKind.always && rule.value.isEmpty) {
        issues.add(CoreConfigIssue('invalid_rule', 'rules.$index'));
      }
    }
    final nodesByTag = {for (final node in profile.nodes) node.tag: node};
    final graph = <String, List<String>>{
      for (final node in profile.nodes)
        node.tag: [if (node.detour != null) node.detour!],
      for (final group in groups.values) group.tag: group.members,
    };
    for (final node in profile.nodes) {
      if (node.detour != null &&
          nodesByTag[node.detour]?.protocol == CoreNodeProtocol.direct) {
        issues.add(
          CoreConfigIssue('empty_direct_detour', 'nodes.${node.tag}.detour'),
        );
      }
      if (node.detour != null && !tags.contains(node.detour)) {
        issues.add(
          CoreConfigIssue('unknown_detour', 'nodes.${node.tag}.detour'),
        );
      }
    }
    final incoming = {for (final name in graph.keys) name: 0};
    for (final edges in graph.values) {
      for (final edge in edges) {
        if (incoming.containsKey(edge)) incoming[edge] = incoming[edge]! + 1;
      }
    }
    final ready = incoming.keys.where((name) => incoming[name] == 0).toList();
    for (var index = 0; index < ready.length; index++) {
      for (final edge in graph[ready[index]]!) {
        if (!incoming.containsKey(edge)) continue;
        incoming[edge] = incoming[edge]! - 1;
        if (incoming[edge] == 0) ready.add(edge);
      }
    }
    if (ready.length != graph.length) {
      issues.add(const CoreConfigIssue('outbound_cycle', 'outbounds'));
    }
    if (listeners.mixedPort < 1 ||
        listeners.mixedPort > 65535 ||
        listeners.controllerPort < 1 ||
        listeners.controllerPort > 65535 ||
        listeners.controllerPort == listeners.mixedPort) {
      issues.add(const CoreConfigIssue('invalid_listener_ports', 'listeners'));
    }
    if (listeners.secret.isEmpty ||
        listeners.secret.contains(RegExp(r'[\r\n]'))) {
      issues.add(
        const CoreConfigIssue('invalid_controller_secret', 'listeners'),
      );
    }
    final tun = listeners.tun;
    if (tun != null) {
      if (tun.interfaceName.trim().isEmpty ||
          tun.interfaceName.contains(RegExp(r'[\r\n]')) ||
          tun.addresses.isEmpty) {
        issues.add(const CoreConfigIssue('invalid_tun', 'listeners.tun'));
      }
      for (final address in tun.addresses) {
        final parts = address.split('/');
        final ip = InternetAddress.tryParse(parts.first);
        final prefix = parts.length == 2 ? int.tryParse(parts.last) : null;
        if (ip == null ||
            prefix == null ||
            prefix < 1 ||
            prefix > ip.rawAddress.length * 8) {
          issues.add(
            const CoreConfigIssue(
              'invalid_tun_address',
              'listeners.tun.addresses',
            ),
          );
        }
      }
    }
    issues.addAll(validateDns(profile, listeners));
    final probe = listeners.probe;
    if (probe != null &&
        (!probe.isValid ||
            [
              listeners.mixedPort,
              listeners.controllerPort,
              listeners.dnsPort,
            ].contains(probe.port))) {
      issues.add(
        const CoreConfigIssue('invalid_probe_listener', 'listeners.probe'),
      );
    }
    if (issues.isNotEmpty) return CoreConfigBuildResult(issues: issues);
    try {
      final encoded = CoreConfigEncoding.encode({
        if (profile.dns case final dns?) 'dns': compileDns(dns),
        'inbounds': [
          if (probe != null)
            {
              'type': 'http',
              'tag': 'hotaru-probe',
              'listen': '127.0.0.1',
              'listen_port': probe.port,
              'users': [
                for (final tag in tags)
                  {
                    'username': CoreProbeListenerSpec.username(tag),
                    'password': probe.secret,
                  },
              ],
            },
          if (listeners.dnsPort != null)
            {
              'type': 'direct',
              'tag': 'dns-in',
              'listen': '127.0.0.1',
              'listen_port': listeners.dnsPort,
            },
          {
            'type': 'mixed',
            'tag': 'mixed',
            'listen': '127.0.0.1',
            'listen_port': listeners.mixedPort,
          },
          if (tun != null)
            {
              'type': 'tun',
              'tag': 'tun',
              'interface_name': tun.interfaceName,
              'address': tun.addresses,
              'auto_route': tun.autoRoute,
              'stack': 'system',
            },
        ],
        'outbounds': [
          for (final node in profile.nodes)
            {
              ..._node(node),
              if (profile.dns?.proxyServer != null &&
                  node.protocol != CoreNodeProtocol.direct)
                'domain_resolver': profile.dns!.proxyServer,
            },
          for (final selector in profile.selectors)
            {
              'type': selector.strategy.name,
              'tag': selector.tag,
              'outbounds': selector.members,
              if (selector.selected != null) 'default': selector.selected,
              if (selector.strategy == CoreGroupStrategy.urltest) ...{
                'url': selector.testUrl,
                'interval': '${selector.interval.inSeconds}s',
                'tolerance': selector.tolerance,
              },
            },
        ],
        'route': {
          'final': profile.finalOutbound,
          if (profile.dns != null)
            'default_domain_resolver': profile.dns!.finalServer,
          if (tun?.autoRoute == true) 'auto_detect_interface': true,
          if (profile.rules.isNotEmpty ||
              probe != null ||
              listeners.dnsPort != null ||
              tun?.hijackDns == true)
            'rules': [
              if (probe != null) ...[
                for (final tag in tags)
                  {
                    'inbound': ['hotaru-probe'],
                    'auth_user': [CoreProbeListenerSpec.username(tag)],
                    'action': 'route',
                    'outbound': tag,
                  },
                {
                  'inbound': ['hotaru-probe'],
                  'action': 'reject',
                },
              ],
              if (listeners.dnsPort != null)
                {
                  'inbound': ['dns-in'],
                  'action': 'hijack-dns',
                },
              if (tun?.hijackDns == true)
                {
                  'inbound': ['tun'],
                  'port': [53],
                  'action': 'hijack-dns',
                },
              for (final rule in profile.rules)
                {
                  if (rule.kind != CoreRuleKind.always)
                    switch (rule.kind) {
                      CoreRuleKind.domain => 'domain',
                      CoreRuleKind.domainSuffix => 'domain_suffix',
                      CoreRuleKind.domainKeyword => 'domain_keyword',
                      CoreRuleKind.ipCidr => 'ip_cidr',
                      CoreRuleKind.always => throw StateError(
                        'Unreachable rule kind',
                      ),
                    }: [
                      rule.value,
                    ],
                  'action': rule.action == CoreRuleAction.route
                      ? 'route'
                      : 'reject',
                  if (rule.action == CoreRuleAction.drop) 'method': 'drop',
                  if (rule.outbound != null) 'outbound': rule.outbound,
                },
            ],
        },
        'experimental': {
          'clash_api': {
            'external_controller': '127.0.0.1:${listeners.controllerPort}',
            'secret': listeners.secret,
          },
        },
      });
      return CoreConfigBuildResult(
        json: utf8.decode(encoded),
        issues: const [],
      );
    } on CoreConfigSizeException {
      return CoreConfigBuildResult(
        issues: [
          const CoreConfigIssue('compiled_config_too_large', 'document'),
        ],
      );
    }
  }

  static Map<String, Object?> _node(CoreNodeSpec node) {
    return {
      'type': node.protocol.name,
      'tag': node.tag,
      if (node.protocol != CoreNodeProtocol.direct) ...{
        'server': node.server,
        'server_port': node.port,
        if (node.detour != null) 'detour': node.detour,
        if (node.username != null) 'username': node.username,
        if (node.password != null) 'password': node.password,
        if (node.uuid != null) 'uuid': node.uuid,
        if (node.protocol == CoreNodeProtocol.shadowsocks)
          'method': node.cipher,
        if (node.protocol == CoreNodeProtocol.vmess) ...{
          'security': node.cipher ?? 'auto',
          'alter_id': node.alterId ?? 0,
        },
        if (node.flow != null && node.flow!.isNotEmpty) 'flow': node.flow,
        if (node.congestionControl != null)
          'congestion_control': node.congestionControl,
        if (node.udpRelayMode != null) 'udp_relay_mode': node.udpRelayMode,
        if (node.upMbps != null) 'up_mbps': node.upMbps,
        if (node.downMbps != null) 'down_mbps': node.downMbps,
        if (node.obfsPassword != null)
          'obfs': {'type': 'salamander', 'password': node.obfsPassword},
        if (node.tcpOnly && node.protocol != CoreNodeProtocol.http)
          'network': 'tcp',
        if (node.tls case final tls?)
          'tls': {
            'enabled': true,
            'insecure': tls.insecure,
            if (tls.serverName != null) 'server_name': tls.serverName,
            if (tls.alpn.isNotEmpty) 'alpn': tls.alpn,
            if (tls.fingerprint != null)
              'utls': {'enabled': true, 'fingerprint': tls.fingerprint},
            if (tls.realityPublicKey != null)
              'reality': {
                'enabled': true,
                'public_key': tls.realityPublicKey,
                if (tls.realityShortId != null) 'short_id': tls.realityShortId,
              },
          },
        if (node.transport case final transport?)
          'transport': {
            'type': transport.kind.name,
            if (transport.path != null) 'path': transport.path,
            if (transport.headers.isNotEmpty) 'headers': transport.headers,
            if (transport.serviceName != null)
              'service_name': transport.serviceName,
          },
      },
    };
  }
}

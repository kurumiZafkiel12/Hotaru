import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import '../config/profile.dart';
import '../config/rule_set.dart';
import '../config/node_validation.dart';
import '../config/test_target.dart';
import '../config/encoding.dart';
import '../config/ip_prefix.dart';
import '../config/probe_listener.dart';
import '../config/mode_outbounds.dart';
import '../config/runtime_options.dart';
import 'dns_config.dart';
import 'rule_sets_config.dart';
import 'runtime_config.dart';

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
    issues.addAll(validateRuleSets(profile));
    issues.addAll(validateRuntimeOptions(profile, listeners));
    final ruleSets = {for (final set in profile.ruleSets) set.tag: set};
    final tags = <String>{};
    void tag(String value, String path) {
      if (value.isEmpty || !tags.add(value)) {
        issues.add(CoreConfigIssue('invalid_or_duplicate_tag', path));
      }
    }

    for (final node in profile.nodes) {
      tag(node.tag, 'nodes.${node.tag}');
      issues.addAll(validateCoreNodeFields(node, path: 'nodes.${node.tag}'));
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
          (!isCoreTestTarget(Uri.tryParse(selector.testUrl)) ||
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
      if (rule.invert && rule.kind != CoreRuleKind.ruleSet) {
        issues.add(
          CoreConfigIssue('unsupported_rule_inversion', 'rules.$index'),
        );
      }
      if (rule.kind == CoreRuleKind.ipCidr) {
        if (CoreIpPrefix.parse(rule.value) == null) {
          issues.add(CoreConfigIssue('invalid_ip_prefix', 'rules.$index'));
        }
      } else if (rule.kind == CoreRuleKind.ruleSet) {
        final set = ruleSets[rule.value];
        if (set == null) {
          issues.add(CoreConfigIssue('unknown_rule_set', 'rules.$index'));
        } else if (rule.noResolve && !set.requiresAddress) {
          issues.add(CoreConfigIssue('unexpected_no_resolve', 'rules.$index'));
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
    final requestedTun = listeners.tun;
    if (requestedTun != null) {
      if (requestedTun.interfaceName.trim().isEmpty ||
          requestedTun.interfaceName.contains(RegExp(r'[\r\n]')) ||
          requestedTun.addresses.isEmpty) {
        issues.add(const CoreConfigIssue('invalid_tun', 'listeners.tun'));
      }
      for (final address in requestedTun.addresses) {
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
    final requestedProbe = listeners.probe;
    if (requestedProbe != null &&
        (!requestedProbe.isValid ||
            [
              ...listeners.dataPorts,
              listeners.controllerPort,
              listeners.dnsPort,
            ].contains(requestedProbe.port))) {
      issues.add(
        const CoreConfigIssue('invalid_probe_listener', 'listeners.probe'),
      );
    }
    final modes = CoreModeOutbounds(profile);
    if (listeners.globalSelection != null &&
        !modes.global.members.contains(listeners.globalSelection)) {
      issues.add(
        const CoreConfigIssue(
          'invalid_global_selection',
          'listeners.globalSelection',
        ),
      );
    }
    if (issues.isNotEmpty) return CoreConfigBuildResult(issues: issues);
    final probe = listeners.activeProbe;
    final tun = listeners.activeTun;
    try {
      final encoded = CoreConfigEncoding.encode({
        if (profile.runtime.logLevel case final level?)
          'log': {
            if (level == 'silent')
              'disabled': true
            else
              'level': level == 'warning' ? 'warn' : level,
          },
        if (profile.dns case final dns?) 'dns': compileDns(dns, listeners),
        'inbounds': [
          for (final group in profile.dns?.groups ?? const [])
            {
              'type': 'direct',
              'tag': dnsGroupInboundTag(group.tag),
              'listen': '127.0.0.1',
              'listen_port': listeners.dnsGroups!.ports[group.tag],
            },
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
          if (listeners.activeDnsPort != null)
            {
              'type': 'direct',
              'tag': 'dns-in',
              'listen': '127.0.0.1',
              'listen_port': listeners.activeDnsPort,
            },
          ...compileDataInbounds(listeners),
          if (tun != null)
            {
              'type': 'tun',
              'tag': 'tun',
              'interface_name': tun.interfaceName,
              'address': tun.addresses,
              'auto_route': tun.autoRoute,
              'stack': 'system',
              if (tun.mtu != null) 'mtu': tun.mtu,
              if (tun.routes.isNotEmpty) 'route_address': tun.routes,
              if (tun.excludedRoutes.isNotEmpty)
                'route_exclude_address': tun.excludedRoutes,
            },
        ],
        'outbounds': [
          _node(modes.direct, profile.runtime),
          {
            'type': 'selector',
            'tag': modes.global.tag,
            'outbounds': modes.global.members,
            'default': listeners.globalSelection ?? modes.global.selected,
          },
          for (final node in profile.nodes)
            {
              ..._node(node, profile.runtime),
              if (profile.dns?.proxyServer != null &&
                  node.protocol != CoreNodeProtocol.direct)
                'domain_resolver': _resolver(
                  profile.dns!.proxyServer!,
                  profile.runtime.resolveIpv6,
                ),
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
          if (profile.runtime.findProcess) 'find_process': true,
          if (profile.runtime.defaultInterface != null)
            'default_interface': profile.runtime.defaultInterface,
          if (profile.ruleSets.any((set) => !set.isEmpty))
            'rule_set': [
              for (final set in profile.ruleSets)
                if (!set.isEmpty) compileRuleSet(set),
            ],
          if (profile.dns != null)
            'default_domain_resolver': _resolver(
              profile.dns!.finalServer,
              profile.runtime.resolveIpv6,
            ),
          if (tun?.autoRoute == true) 'auto_detect_interface': true,
          'rules': [
            for (final group in profile.dns?.groups ?? const [])
              {
                'inbound': [dnsGroupInboundTag(group.tag)],
                'action': 'hijack-dns',
              },
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
            if (listeners.activeDnsPort != null)
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
            {
              'clash_mode': 'direct',
              'action': 'route',
              'outbound': modes.direct.tag,
            },
            {
              'clash_mode': 'global',
              'action': 'route',
              'outbound': modes.global.tag,
            },
            ..._profileRules(profile.rules, ruleSets),
            {
              'clash_mode': 'rule',
              'action': 'route',
              'outbound': profile.finalOutbound,
            },
          ],
        },
        'experimental': {
          'clash_api': {
            'external_controller': '127.0.0.1:${listeners.controllerPort}',
            'secret': listeners.secret,
            'default_mode': listeners.initialMode.name,
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

  static List<Map<String, Object?>> _profileRules(
    List<CoreRouteRule> rules,
    Map<String, CoreRuleSetSpec> sets,
  ) {
    final result = <Map<String, Object?>>[];
    var resolved = false;
    for (final rule in rules) {
      final needsAddress =
          rule.kind == CoreRuleKind.ipCidr ||
          rule.kind == CoreRuleKind.ruleSet &&
              sets[rule.value]!.requiresAddress;
      if (!resolved && !rule.noResolve && needsAddress) {
        result.add({'action': 'resolve'});
        resolved = true;
      }
      final native = _rule(rule, sets);
      if (native != null) result.add(native);
    }
    return result;
  }

  static Object _resolver(String tag, bool ipv6) =>
      ipv6 ? tag : <String, Object?>{'server': tag, 'strategy': 'ipv4_only'};

  static Map<String, Object?>? _rule(
    CoreRouteRule rule,
    Map<String, CoreRuleSetSpec> sets,
  ) {
    final Map<String, Object?>? match;
    if (rule.kind == CoreRuleKind.ruleSet) {
      match = compileRuleSetMatch(sets[rule.value]!, rule.invert);
    } else {
      match = {
        if (rule.kind != CoreRuleKind.always)
          switch (rule.kind) {
            CoreRuleKind.domain => 'domain',
            CoreRuleKind.domainSuffix => 'domain_suffix',
            CoreRuleKind.domainKeyword => 'domain_keyword',
            CoreRuleKind.ipCidr => 'ip_cidr',
            _ => throw StateError('Unreachable rule kind'),
          }: [
            rule.value,
          ],
        if (rule.invert) 'invert': true,
      };
    }
    if (match == null) return null;
    return {
      ...match,
      'action': rule.action == CoreRuleAction.route ? 'route' : 'reject',
      if (rule.action == CoreRuleAction.drop) 'method': 'drop',
      if (rule.outbound != null) 'outbound': rule.outbound,
    };
  }

  static Map<String, Object?> _node(
    CoreNodeSpec node,
    CoreRuntimeOptions runtime,
  ) {
    return {
      'type': node.protocol.name,
      'tag': node.tag,
      if (runtime.disableTcpKeepAlive) 'disable_tcp_keep_alive': true,
      if (runtime.tcpKeepAliveSeconds != null)
        'tcp_keep_alive': '${runtime.tcpKeepAliveSeconds}s',
      if (runtime.tcpKeepAliveIntervalSeconds != null)
        'tcp_keep_alive_interval': '${runtime.tcpKeepAliveIntervalSeconds}s',
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
            'insecure': tls.insecure || runtime.skipCertVerify,
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

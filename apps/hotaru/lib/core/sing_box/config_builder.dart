import 'dart:convert';
import 'dart:isolate';

import '../config/profile.dart';

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
      if (node.protocol == CoreNodeProtocol.direct) {
        if (node.server != null ||
            node.port != null ||
            node.username != null ||
            node.password != null) {
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
      if ((node.username == null) != (node.password == null)) {
        issues.add(
          CoreConfigIssue('incomplete_credentials', 'nodes.${node.tag}'),
        );
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
    }
    final incoming = {for (final name in groups.keys) name: 0};
    for (final group in groups.values) {
      for (final member in group.members) {
        if (groups.containsKey(member)) {
          incoming[member] = incoming[member]! + 1;
        }
      }
    }
    final ready = incoming.keys.where((name) => incoming[name] == 0).toList();
    for (var index = 0; index < ready.length; index++) {
      for (final member in groups[ready[index]]!.members) {
        if (!groups.containsKey(member)) continue;
        incoming[member] = incoming[member]! - 1;
        if (incoming[member] == 0) ready.add(member);
      }
    }
    if (ready.length != groups.length) {
      issues.add(const CoreConfigIssue('selector_cycle', 'selectors'));
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
    if (issues.isNotEmpty) return CoreConfigBuildResult(issues: issues);
    return CoreConfigBuildResult(
      json: jsonEncode({
        'inbounds': [
          {
            'type': 'mixed',
            'tag': 'mixed',
            'listen': '127.0.0.1',
            'listen_port': listeners.mixedPort,
          },
        ],
        'outbounds': [
          for (final node in profile.nodes)
            {
              'type': node.protocol.name,
              'tag': node.tag,
              if (node.protocol != CoreNodeProtocol.direct) ...{
                'server': node.server,
                'server_port': node.port,
                if (node.username != null) 'username': node.username,
                if (node.password != null) 'password': node.password,
              },
            },
          for (final selector in profile.selectors)
            {
              'type': 'selector',
              'tag': selector.tag,
              'outbounds': selector.members,
              if (selector.selected != null) 'default': selector.selected,
            },
        ],
        'route': {'final': profile.finalOutbound},
        'experimental': {
          'clash_api': {
            'external_controller': '127.0.0.1:${listeners.controllerPort}',
            'secret': listeners.secret,
          },
        },
      }),
      issues: const [],
    );
  }
}

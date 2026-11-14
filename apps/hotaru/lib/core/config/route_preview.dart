import 'dart:io' show InternetAddress;
import 'dart:isolate';

import 'profile.dart';
import 'ip_prefix.dart';
import 'mode_outbounds.dart';
import 'rule_set.dart';
import '../routing_mode.dart';

abstract interface class CoreRoutePreviewSource {
  Future<CoreRoutePreview> previewRoute(String target);
}

enum CoreRoutePreviewStatus {
  resolved,
  addressRequired,
  contextRequired,
  selectionRequired,
  invalidTarget,
  invalidProfile,
}

final class CoreRoutePreview {
  final CoreRoutePreviewStatus status;
  final String target;
  final int? ruleIndex;
  final CoreRouteRule? rule;
  final CoreRuleAction? action;
  final List<String> chain;
  final List<String> hops;
  final Map<String, String> selectedOutbounds;

  CoreRoutePreview({
    required this.status,
    required this.target,
    this.ruleIndex,
    this.rule,
    this.action,
    List<String> chain = const [],
    List<String> hops = const [],
    Map<String, String> selectedOutbounds = const {},
  }) : chain = List.unmodifiable(chain),
       hops = List.unmodifiable(hops),
       selectedOutbounds = Map.unmodifiable(selectedOutbounds);
}

final class CoreRoutePreviewer {
  // Selections must be a snapshot from the same applied profile/session.
  Future<CoreRoutePreview> preview(
    CoreProfileSpec profile,
    String target, {
    Map<String, String> selections = const {},
    CoreRoutingMode mode = CoreRoutingMode.rule,
  }) {
    final snapshot = Map<String, String>.of(selections);
    return Isolate.run(() {
      final modes = CoreModeOutbounds(profile);
      return _preview(
        target,
        nodes: [...profile.nodes, modes.direct],
        selectors: [...profile.selectors, modes.global],
        rules: mode == CoreRoutingMode.rule ? profile.rules : const [],
        ruleSets: profile.ruleSets,
        finalOutbound: switch (mode) {
          CoreRoutingMode.rule => profile.finalOutbound,
          CoreRoutingMode.global => modes.global.tag,
          CoreRoutingMode.direct => modes.direct.tag,
        },
        selections: snapshot,
        global: modes.global.tag,
      );
    });
  }

  static CoreRoutePreview _preview(
    String input, {
    required List<CoreNodeSpec> nodes,
    required List<CoreSelectorSpec> selectors,
    required List<CoreRouteRule> rules,
    required List<CoreRuleSetSpec> ruleSets,
    required String finalOutbound,
    required String global,
    required Map<String, String> selections,
  }) {
    final target = input.trim().toLowerCase();
    final address = InternetAddress.tryParse(target);
    if (address == null && !_validDomain(target) ||
        address != null &&
            CoreIpPrefix.parse('$target/${address.rawAddress.length * 8}') ==
                null) {
      return CoreRoutePreview(
        status: CoreRoutePreviewStatus.invalidTarget,
        target: target,
      );
    }
    final nodeMap = {for (final node in nodes) node.tag: node};
    final groups = {for (final group in selectors) group.tag: group};
    final sets = {for (final set in ruleSets) set.tag: set};
    if (nodeMap.length != nodes.length ||
        sets.length != ruleSets.length ||
        groups.length != selectors.length ||
        groups.keys.any(nodeMap.containsKey)) {
      return CoreRoutePreview(
        status: CoreRoutePreviewStatus.invalidProfile,
        target: target,
      );
    }

    int? ruleIndex;
    CoreRouteRule? matched;
    for (var index = 0; index < rules.length; index++) {
      final rule = rules[index];
      if (rule.invert && rule.kind != CoreRuleKind.ruleSet) {
        return CoreRoutePreview(
          status: CoreRoutePreviewStatus.invalidProfile,
          target: target,
          ruleIndex: index,
          rule: rule,
        );
      }
      final value = rule.value;
      bool matches;
      switch (rule.kind) {
        case CoreRuleKind.always:
          matches = true;
        case CoreRuleKind.domain:
          matches = address == null && target == value;
        case CoreRuleKind.domainSuffix:
          matches =
              address == null &&
              (value.startsWith('.')
                  ? target.endsWith(value)
                  : target == value || target.endsWith('.$value'));
        case CoreRuleKind.domainKeyword:
          matches = address == null && target.contains(value);
        case CoreRuleKind.ipCidr:
          final cidr = CoreIpPrefix.parse(value);
          if (cidr == null) {
            return CoreRoutePreview(
              status: CoreRoutePreviewStatus.invalidProfile,
              target: target,
              ruleIndex: index,
              rule: rule,
            );
          }
          if (address == null) {
            if (rule.noResolve) continue;
            return CoreRoutePreview(
              status: CoreRoutePreviewStatus.addressRequired,
              target: target,
              ruleIndex: index,
              rule: rule,
            );
          }
          matches = cidr.contains(address);
        case CoreRuleKind.ruleSet:
          final set = sets[value];
          if (set == null) {
            return CoreRoutePreview(
              status: CoreRoutePreviewStatus.invalidProfile,
              target: target,
              ruleIndex: index,
              rule: rule,
            );
          }
          if (address != null && set.kind == CoreRuleSetKind.domain ||
              address == null &&
                  set.kind == CoreRuleSetKind.ipCidr &&
                  rule.noResolve) {
            continue;
          }
          if (address == null && set.requiresAddress && !rule.noResolve) {
            return CoreRoutePreview(
              status: CoreRoutePreviewStatus.addressRequired,
              target: target,
              ruleIndex: index,
              rule: rule,
            );
          }
          if (address != null) {
            matches = false;
            for (final prefix in set.prefixes) {
              final parsed = CoreIpPrefix.parse(prefix);
              if (parsed == null) {
                return CoreRoutePreview(
                  status: CoreRoutePreviewStatus.invalidProfile,
                  target: target,
                  ruleIndex: index,
                  rule: rule,
                );
              }
              if (parsed.contains(address)) matches = true;
            }
          } else {
            matches =
                set.domains.contains(target) ||
                set.suffixes.any(
                  (suffix) => suffix.startsWith('.')
                      ? target.endsWith(suffix)
                      : target == suffix || target.endsWith('.$suffix'),
                ) ||
                set.keywords.any(target.contains);
            if (!matches && set.regexes.isNotEmpty) {
              return CoreRoutePreview(
                status: CoreRoutePreviewStatus.contextRequired,
                target: target,
                ruleIndex: index,
                rule: rule,
              );
            }
          }
      }
      if (rule.kind != CoreRuleKind.always && value.isEmpty) {
        return CoreRoutePreview(
          status: CoreRoutePreviewStatus.invalidProfile,
          target: target,
          ruleIndex: index,
          rule: rule,
        );
      }
      if (rule.invert) matches = !matches;
      if (!matches) continue;
      ruleIndex = index;
      matched = rule;
      break;
    }

    final action = matched?.action ?? CoreRuleAction.route;
    final chain = <String>[];
    final physical = <String>[];
    final selectedOutbounds = <String, String>{};
    CoreRoutePreview result(CoreRoutePreviewStatus status) => CoreRoutePreview(
      status: status,
      target: target,
      ruleIndex: ruleIndex,
      rule: matched,
      action: action,
      chain: chain,
      hops: status == CoreRoutePreviewStatus.resolved
          ? physical.reversed.toList()
          : const [],
      selectedOutbounds: selectedOutbounds,
    );
    if (action == CoreRuleAction.reject || action == CoreRuleAction.drop) {
      return result(
        matched?.outbound == null
            ? CoreRoutePreviewStatus.resolved
            : CoreRoutePreviewStatus.invalidProfile,
      );
    }
    if (action == CoreRuleAction.global && matched?.outbound != null) {
      return result(CoreRoutePreviewStatus.invalidProfile);
    }
    var next = action == CoreRuleAction.global
        ? global
        : matched == null
        ? finalOutbound
        : matched.outbound;
    final visited = <String>{};
    var followsDetour = false;
    while (next != null && visited.add(next)) {
      if (!followsDetour) chain.add(next);
      final node = nodeMap[next];
      if (node != null) {
        physical.add(next);
        if (node.detour == null) return result(CoreRoutePreviewStatus.resolved);
        followsDetour = true;
        next = node.detour;
        continue;
      }
      final group = groups[next];
      if (group == null) return result(CoreRoutePreviewStatus.invalidProfile);
      final selected = selections[next];
      if (selected == null) {
        return result(CoreRoutePreviewStatus.selectionRequired);
      }
      if (!group.members.contains(selected)) {
        return result(CoreRoutePreviewStatus.invalidProfile);
      }
      selectedOutbounds[next] = selected;
      next = selected;
    }
    return result(CoreRoutePreviewStatus.invalidProfile);
  }

  static bool _validDomain(String value) {
    if (value.isEmpty || value.length > 253) return false;
    return value
        .split('.')
        .every(
          (label) =>
              label.isNotEmpty &&
              label.length <= 63 &&
              RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
        );
  }
}

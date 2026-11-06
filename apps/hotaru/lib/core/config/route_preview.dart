import 'dart:io' show InternetAddress;
import 'dart:isolate';

import 'profile.dart';
import 'ip_prefix.dart';

enum CoreRoutePreviewStatus {
  resolved,
  addressRequired,
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
  }) {
    final snapshot = Map<String, String>.of(selections);
    final nodes = profile.nodes;
    final selectors = profile.selectors;
    final rules = profile.rules;
    final finalOutbound = profile.finalOutbound;
    return Isolate.run(
      () => _preview(
        target,
        nodes: nodes,
        selectors: selectors,
        rules: rules,
        finalOutbound: finalOutbound,
        selections: snapshot,
      ),
    );
  }

  static CoreRoutePreview _preview(
    String input, {
    required List<CoreNodeSpec> nodes,
    required List<CoreSelectorSpec> selectors,
    required List<CoreRouteRule> rules,
    required String finalOutbound,
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
    if (nodeMap.length != nodes.length ||
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
      }
      if (rule.kind != CoreRuleKind.always && value.isEmpty) {
        return CoreRoutePreview(
          status: CoreRoutePreviewStatus.invalidProfile,
          target: target,
          ruleIndex: index,
          rule: rule,
        );
      }
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
    if (action != CoreRuleAction.route) {
      return result(
        matched?.outbound == null
            ? CoreRoutePreviewStatus.resolved
            : CoreRoutePreviewStatus.invalidProfile,
      );
    }
    var next = matched == null ? finalOutbound : matched.outbound;
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

import 'dart:io' show InternetAddress;
import 'dart:isolate';

import 'profile.dart';

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

  CoreRoutePreview({
    required this.status,
    required this.target,
    this.ruleIndex,
    this.rule,
    this.action,
    List<String> chain = const [],
  }) : chain = List.unmodifiable(chain);
}

final class CoreRoutePreviewer {
  // Selections must be a snapshot from the same applied profile/session.
  Future<CoreRoutePreview> preview(
    CoreProfileSpec profile,
    String target, {
    Map<String, String> selections = const {},
  }) {
    final snapshot = Map<String, String>.of(selections);
    final nodeTags = profile.nodes.map((node) => node.tag).toList();
    final selectors = profile.selectors;
    final rules = profile.rules;
    final finalOutbound = profile.finalOutbound;
    return Isolate.run(
      () => _preview(
        target,
        nodeTags: nodeTags,
        selectors: selectors,
        rules: rules,
        finalOutbound: finalOutbound,
        selections: snapshot,
      ),
    );
  }

  static CoreRoutePreview _preview(
    String input, {
    required List<String> nodeTags,
    required List<CoreSelectorSpec> selectors,
    required List<CoreRouteRule> rules,
    required String finalOutbound,
    required Map<String, String> selections,
  }) {
    final target = input.trim().toLowerCase();
    final address = InternetAddress.tryParse(target);
    if (address == null && !_validDomain(target)) {
      return CoreRoutePreview(
        status: CoreRoutePreviewStatus.invalidTarget,
        target: target,
      );
    }
    final nodes = nodeTags.toSet();
    final groups = {for (final group in selectors) group.tag: group};
    if (nodes.length != nodeTags.length ||
        groups.length != selectors.length ||
        groups.keys.any(nodes.contains)) {
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
          final cidr = _Cidr.parse(value);
          if (cidr == null) {
            return CoreRoutePreview(
              status: CoreRoutePreviewStatus.invalidProfile,
              target: target,
              ruleIndex: index,
              rule: rule,
            );
          }
          if (address == null) {
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
    CoreRoutePreview result(CoreRoutePreviewStatus status) => CoreRoutePreview(
      status: status,
      target: target,
      ruleIndex: ruleIndex,
      rule: matched,
      action: action,
      chain: chain,
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
    while (next != null && visited.add(next)) {
      chain.add(next);
      if (nodes.contains(next)) {
        return result(CoreRoutePreviewStatus.resolved);
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

final class _Cidr {
  final InternetAddress network;
  final int prefix;

  const _Cidr(this.network, this.prefix);

  static _Cidr? parse(String value) {
    final parts = value.split('/');
    if (parts.length != 2) return null;
    final network = InternetAddress.tryParse(parts.first);
    final prefix = int.tryParse(parts.last);
    if (network == null ||
        prefix == null ||
        prefix < 0 ||
        prefix > network.rawAddress.length * 8) {
      return null;
    }
    return _Cidr(network, prefix);
  }

  bool contains(InternetAddress address) {
    final bytes = address.rawAddress;
    final networkBytes = network.rawAddress;
    if (bytes.length != networkBytes.length) return false;
    for (var index = 0; index < prefix ~/ 8; index++) {
      if (bytes[index] != networkBytes[index]) return false;
    }
    final remainder = prefix % 8;
    if (remainder == 0) return true;
    final mask = (0xff << (8 - remainder)) & 0xff;
    return bytes[prefix ~/ 8] & mask == networkBytes[prefix ~/ 8] & mask;
  }
}

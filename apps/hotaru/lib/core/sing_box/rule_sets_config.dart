import '../config/ip_prefix.dart';
import '../config/profile.dart';
import '../config/rule_set.dart';

List<CoreConfigIssue> validateRuleSets(CoreProfileSpec profile) =>
    validateCoreRuleSets(profile.ruleSets);

List<CoreConfigIssue> validateCoreRuleSets(
  List<CoreRuleSetSpec> sets, {
  String path = 'ruleSets',
  int limit = 1024,
}) {
  final issues = <CoreConfigIssue>[];
  final names = <String>{};
  var entries = 0;
  if (sets.length > limit) {
    return [CoreConfigIssue('rule_set_limit', path)];
  }
  final root = path;
  for (final set in sets) {
    final path = '$root.${set.tag}';
    if (set.tag.isEmpty || !names.add(set.tag)) {
      issues.add(CoreConfigIssue('invalid_rule_set_tag', path));
    }
    final domains = [set.domains, set.suffixes, set.keywords, set.regexes];
    entries += set.prefixes.length;
    for (final values in domains) {
      entries += values.length;
    }
    if (entries > CoreRuleSetSpec.maxEntries) {
      issues.add(CoreConfigIssue('rule_set_entry_limit', root));
      break;
    }
    if (set.kind == CoreRuleSetKind.domain && set.prefixes.isNotEmpty ||
        set.kind == CoreRuleSetKind.ipCidr &&
            domains.any((values) => values.isNotEmpty)) {
      issues.add(CoreConfigIssue('invalid_rule_set_kind', path));
    }
    if (domains.any((values) => values.any((value) => value.isEmpty)) ||
        set.prefixes.any((value) => CoreIpPrefix.parse(value) == null)) {
      issues.add(CoreConfigIssue('invalid_rule_set_matcher', path));
    }
  }
  return issues;
}

Map<String, Object?> compileRuleSet(CoreRuleSetSpec set) => {
  'type': 'inline',
  'tag': set.tag,
  'rules': [
    if (set.domains.isNotEmpty) {'domain': set.domains},
    if (set.suffixes.isNotEmpty) {'domain_suffix': set.suffixes},
    if (set.keywords.isNotEmpty) {'domain_keyword': set.keywords},
    if (set.regexes.isNotEmpty) {'domain_regex': set.regexes},
    if (set.prefixes.isNotEmpty) {'ip_cidr': set.prefixes},
  ],
};

Map<String, Object?>? compileRuleSetMatch(CoreRuleSetSpec set, bool invert) {
  if (set.isEmpty && !invert) return null;
  final guard = switch (set.kind) {
    CoreRuleSetKind.domain => <String, Object?>{
      'domain_regex': ['.'],
    },
    CoreRuleSetKind.ipCidr => <String, Object?>{
      'ip_cidr': ['0.0.0.0/0', '::/0'],
    },
    CoreRuleSetKind.mixed => <String, Object?>{},
  };
  if (set.isEmpty) return guard;
  final match = <String, Object?>{
    'rule_set': [set.tag],
    if (invert) 'invert': true,
  };
  if (!invert || guard.isEmpty) return match;
  return {
    'type': 'logical',
    'mode': 'and',
    'rules': [guard, match],
  };
}

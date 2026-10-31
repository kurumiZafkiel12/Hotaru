import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/clash_config.dart';

class UnsupportedRoutingRule extends FormatException {
  const UnsupportedRoutingRule(this.line, this.type)
    : super('unsupported routing rule');

  final int line;
  final String type;
}

class RoutingRules {
  const RoutingRules({
    required this.rules,
    required this.providers,
    required this.subRules,
  });

  final List<String> rules;
  final Map<String, dynamic> providers;
  final Map<String, List<String>> subRules;

  factory RoutingRules.parse(String source) {
    if (source.length > 2 * 1024 * 1024) {
      throw const FormatException('routing configuration too large');
    }
    final document = source.replaceFirst('\uFEFF', '');
    final parsed =
        RegExp(
          r'^\s*\[Rule\]\s*(?:#.*)?$',
          multiLine: true,
          caseSensitive: false,
        ).hasMatch(document)
        ? _shadowrocket(document)
        : loadYaml(document);
    if (parsed is! Map) {
      throw const FormatException('expected a Mihomo YAML document');
    }
    final raw = jsonDecode(jsonEncode(parsed)) as Map<String, dynamic>;
    List<String> readRules(Object? value) {
      if (value is! List || value.any((rule) => rule is! String)) {
        throw const FormatException('expected a rule list');
      }
      return value.cast<String>().map((value) {
        final rule = value.trim();
        final type = rule.split(',').first.toUpperCase();
        if (!RuleAction.values.any((action) => action.value == type)) {
          throw const FormatException('unsupported rule type');
        }
        final parsed = Rule.parse(rule, id: 0);
        if (parsed.realTarget?.isNotEmpty != true) {
          throw const FormatException('rule target missing');
        }
        return rule;
      }).toList();
    }

    final rules = readRules(raw['rules']);
    if (rules.isEmpty) throw const FormatException('routing rules are empty');
    final providers = raw['rule-providers'] ?? <String, dynamic>{};
    if (providers is! Map<String, dynamic>) {
      throw const FormatException('invalid rule providers');
    }
    for (final entry in providers.entries) {
      final provider = entry.value;
      if (provider is! Map ||
          !const ['http', 'inline'].contains(provider['type'])) {
        throw const FormatException('rule providers must be HTTP or inline');
      }
      if (provider['type'] == 'http') {
        final uri = Uri.tryParse('${provider['url'] ?? ''}');
        if (uri == null ||
            !const ['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty) {
          throw const FormatException('invalid rule provider URL');
        }
      }
    }
    final rawSubRules = raw['sub-rules'] ?? <String, dynamic>{};
    if (rawSubRules is! Map<String, dynamic>) {
      throw const FormatException('invalid sub-rules');
    }
    final subRules = {
      for (final entry in rawSubRules.entries)
        entry.key: readRules(entry.value),
    };
    for (final line in [
      ...rules,
      ...subRules.values.expand((value) => value),
    ]) {
      final rule = Rule.parse(line, id: 0);
      if (rule.ruleAction == RuleAction.RULE_SET &&
          !providers.containsKey(rule.ruleProvider)) {
        throw const FormatException('rule provider missing');
      }
      if (rule.ruleAction == RuleAction.SUB_RULE &&
          !subRules.containsKey(rule.subRule)) {
        throw const FormatException('sub-rule missing');
      }
    }
    return RoutingRules(rules: rules, providers: providers, subRules: subRules);
  }

  static Map<String, dynamic> _shadowrocket(String source) {
    final rules = <String>[];
    final providers = <String, dynamic>{};
    var section = '';
    for (final (index, original)
        in const LineSplitter().convert(source).indexed) {
      final line = original.trim();
      if (line.isEmpty ||
          line.startsWith('#') ||
          line.startsWith(';') ||
          line.startsWith('//')) {
        continue;
      }
      final header = RegExp(r'^\[([^\]]+)\]\s*(?:#.*)?$').firstMatch(line);
      if (header != null) {
        section = header.group(1)!.toLowerCase();
        continue;
      }
      if (section != 'rule') continue;
      final parts = line
          .replaceFirst(RegExp(r'\s+#.*$'), '')
          .split(',')
          .map((item) => item.trim())
          .toList();
      final type = switch (parts.first.toUpperCase()) {
        'FINAL' => 'MATCH',
        'IP6-CIDR' => 'IP-CIDR6',
        'DEST-PORT' => 'DST-PORT',
        final type => type,
      };
      if (!RuleAction.values.any((action) => action.value == type) ||
          type == 'SUB-RULE' ||
          parts.any(
            (part) =>
                part.toUpperCase().startsWith('REJECT-') &&
                part.toUpperCase() != 'REJECT-DROP',
          )) {
        throw UnsupportedRoutingRule(index + 1, parts.first);
      }
      parts[0] = type;
      if (type == 'RULE-SET') {
        if (parts.length < 3 ||
            parts.length > 4 ||
            (parts.length == 4 && parts.last != 'no-resolve')) {
          throw UnsupportedRoutingRule(index + 1, type);
        }
        final uri = Uri.tryParse(parts[1]);
        if (uri == null ||
            !const ['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty) {
          throw UnsupportedRoutingRule(index + 1, type);
        }
        final name = 'hotaru-conf-${providers.length + 1}';
        providers[name] = {
          'type': 'http',
          'behavior': 'classical',
          'format': 'text',
          'url': uri.toString(),
          'interval': 86400,
        };
        parts[1] = name;
      }
      if ((type == 'MATCH' && parts.length != 2) ||
          (type != 'MATCH' && parts.length < 3)) {
        throw UnsupportedRoutingRule(index + 1, type);
      }
      final rule = Rule.parse(parts.join(','), id: 0);
      final policy = rule.ruleTarget?.toUpperCase();
      if (policy == null || policy.isEmpty) {
        throw UnsupportedRoutingRule(index + 1, type);
      }
      rules.add(
        const {'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS'}.contains(policy)
            ? rule.copyWith(ruleTarget: policy).rawValue
            : rule.rawValue,
      );
    }
    return {'rules': rules, 'rule-providers': providers};
  }

  Map<String, dynamic> apply(
    Map<String, dynamic> subscription,
    String selectedOutbound,
  ) {
    final names = <String>{
      for (final section in ['proxies', 'proxy-groups'])
        for (final item in subscription[section] as List? ?? const [])
          if (item is Map && item['name'] is String) item['name'] as String,
    };
    if (selectedOutbound.isEmpty || !names.contains(selectedOutbound)) {
      throw const FormatException(
        'selected outbound is not in the subscription',
      );
    }
    String retarget(String line) {
      final rule = Rule.parse(line, id: 0);
      if (rule.ruleAction == RuleAction.SUB_RULE ||
          const {
            'DIRECT',
            'REJECT',
            'REJECT-DROP',
            'PASS',
          }.contains(rule.ruleTarget)) {
        return rule.rawValue;
      }
      return rule.copyWith(ruleTarget: selectedOutbound).rawValue;
    }

    return {
      ...subscription,
      'rules': rules.map(retarget).toList(),
      'rule-providers': jsonDecode(jsonEncode(providers)),
      'sub-rules': {
        for (final entry in subRules.entries)
          entry.key: entry.value.map(retarget).toList(),
      },
    };
  }
}

Map<String, dynamic> composeRoutingRules(
  (Map<String, dynamic>, String, String) input,
) => RoutingRules.parse(input.$2).apply(input.$1, input.$3);

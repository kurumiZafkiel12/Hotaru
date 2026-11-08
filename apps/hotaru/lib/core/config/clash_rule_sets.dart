import 'dart:convert';
import 'dart:isolate';

import 'package:yaml/yaml.dart';

import 'profile.dart';
import 'provider_info.dart';
import 'geodata.dart';
import 'encoding.dart';
import 'ip_prefix.dart';
import 'yaml_document.dart';

final class CoreRuleProviderRequest {
  final String name;
  final int index;
  final Uri? url;
  final String? path;
  final String? outbound;
  final String format;
  final String behavior;
  final Duration interval;
  final Duration timeout;
  final int maxBytes;

  const CoreRuleProviderRequest({
    required this.name,
    required this.index,
    required this.url,
    required this.path,
    required this.outbound,
    required this.format,
    required this.behavior,
    required this.interval,
    required this.timeout,
    required this.maxBytes,
  });
}

typedef CoreRuleProviderResolver =
    Future<String> Function(CoreRuleProviderRequest request);

final class ExpandedClashRules {
  final Map<String, dynamic>? document;
  final List<CoreConfigIssue> issues;

  final Map<String, int> counts;
  final List<CoreProviderInfo> providers;
  ExpandedClashRules(
    this.document,
    List<CoreConfigIssue> issues, {
    Map<String, int> counts = const {},
    List<CoreProviderInfo> providers = const [],
  }) : issues = List.unmodifiable(issues),
       counts = Map.unmodifiable(counts),
       providers = List.unmodifiable(providers);
}

final class ClashRuleSetImporter {
  final CoreRuleProviderResolver? resolve;
  final Duration timeout;
  final int concurrency;

  ClashRuleSetImporter({
    this.resolve,
    this.timeout = const Duration(seconds: 20),
    this.concurrency = 4,
  }) {
    if (concurrency < 1 || concurrency > 16 || timeout <= Duration.zero) {
      throw ArgumentError('Invalid rule provider resolution bounds');
    }
  }

  Future<ExpandedClashRules> expand(Map<String, dynamic> document) async {
    final plan = await _planRules(document, timeout);
    if (_errors(plan.issues)) return ExpandedClashRules(null, plan.issues);
    final issues = [...plan.issues];
    final payloads = <String, String>{};
    final loaded = <String, DateTime>{};
    var next = 0;
    var total = 0;
    var aborted = false;
    Future<void> worker() async {
      while (!aborted && next < plan.requests.length) {
        final request = plan.requests[next++];
        final path = 'rule-providers.${request.index}';
        if (resolve == null) {
          issues.add(CoreConfigIssue('rule_provider_resolver_required', path));
          aborted = true;
          return;
        }
        try {
          final payload = await resolve!(request).timeout(timeout);
          final size = payload.length > request.maxBytes
              ? request.maxBytes + 1
              : await _size(payload);
          if (size > request.maxBytes) {
            issues.add(
              CoreConfigIssue('rule_provider_payload_too_large', path),
            );
            aborted = true;
          } else if ((total += size) > _RuleImport.totalLimit) {
            issues.add(
              CoreConfigIssue('rule_provider_total_size_exceeded', path),
            );
            aborted = true;
          } else {
            payloads[request.name] = payload;
            loaded[request.name] = DateTime.now().toUtc();
          }
        } catch (_) {
          issues.add(CoreConfigIssue('rule_provider_resolution_failed', path));
          aborted = true;
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    if (_errors(issues)) return ExpandedClashRules(null, issues);
    final expanded = await _expandRules(plan, payloads);
    return ExpandedClashRules(
      expanded.document,
      [...issues, ...expanded.issues],
      providers: [
        for (final request in plan.requests)
          CoreProviderInfo(
            name: request.name,
            kind: CoreProviderKind.rule,
            vehicle: request.url == null
                ? CoreProviderVehicle.file
                : CoreProviderVehicle.http,
            path: request.path,
            count: expanded.counts[request.name] ?? 0,
            loadedAt: loaded[request.name]!,
            interval: request.interval,
          ),
      ],
    );
  }
}

bool _errors(List<CoreConfigIssue> issues) =>
    issues.any((issue) => issue.severity == CoreConfigIssueSeverity.error);
Future<int> _size(String payload) =>
    Isolate.run(() => utf8.encode(payload).length);
Future<_RulePlan> _planRules(Map<String, dynamic> document, Duration timeout) =>
    Isolate.run(() => _RuleImport().plan(document, timeout));
Future<ExpandedClashRules> _expandRules(
  _RulePlan plan,
  Map<String, String> payloads,
) => Isolate.run(() => _RuleImport().expand(plan, payloads));

final class _RulePlan {
  final Map<String, dynamic> document;
  final List<CoreRuleProviderRequest> requests;
  final Map<String, List<dynamic>> inline;
  final Map<String, String> behaviors;
  final List<CoreConfigIssue> issues;
  const _RulePlan(
    this.document,
    this.requests,
    this.inline,
    this.behaviors,
    this.issues,
  );
}

final class _RuleImport {
  static const payloadLimit = 16 * 1024 * 1024;
  static const totalLimit = 32 * 1024 * 1024;
  static const ruleLimit = 250000;
  final issues = <CoreConfigIssue>[];
  void issue(String code, String path, {bool warning = false}) => issues.add(
    CoreConfigIssue(
      code,
      path,
      severity: warning
          ? CoreConfigIssueSeverity.warning
          : CoreConfigIssueSeverity.error,
    ),
  );
  Map<String, dynamic> map(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException();
    }
    return Map<String, dynamic>.from(value);
  }

  String text(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.contains(RegExp(r'[\r\n\x00]'))) {
      throw const FormatException();
    }
    return value;
  }

  _RulePlan plan(Map<String, dynamic> document, Duration timeout) {
    final requests = <CoreRuleProviderRequest>[];
    final inline = <String, List<dynamic>>{};
    final behaviors = <String, String>{};
    try {
      if (utf8.encode(jsonEncode(document)).length > totalLimit) {
        throw const FormatException();
      }
      final providers = map(document['rule-providers'] ?? <String, dynamic>{});
      if (providers.length > 64) throw const FormatException();
      var index = 0;
      for (final entry in providers.entries) {
        final path = 'rule-providers.$index';
        try {
          text(entry.key);
          final value = map(entry.value);
          for (final key in value.keys) {
            if (!const {
              'type',
              'behavior',
              'format',
              'url',
              'path',
              'proxy',
              'interval',
              'payload',
            }.contains(key)) {
              issue('unsupported_rule_provider_field', '$path.$key');
            }
          }
          final type = text(value['type']);
          final behavior = text(value['behavior']);
          final format = text(value['format'] ?? 'yaml');
          if (!const {'domain', 'ipcidr', 'classical'}.contains(behavior)) {
            issue('rule_provider_behavior_not_migrated', path);
          }
          if (!const {'yaml', 'text'}.contains(format)) {
            issue('rule_provider_format_not_migrated', path);
          }
          final interval = value['interval'] ?? 0;
          if (interval is! int || interval < 0) throw const FormatException();
          final local = value['path'] == null ? null : text(value['path']);
          if (local != null &&
              (local.startsWith(RegExp(r'[/\\]')) ||
                  local.contains(':') ||
                  local.split(RegExp(r'[/\\]')).contains('..'))) {
            throw const FormatException();
          }
          behaviors[entry.key] = behavior;
          if (type == 'inline') {
            if (value.keys.any(
              (key) => const {
                'url',
                'path',
                'proxy',
                'interval',
                'format',
              }.contains(key),
            )) {
              issue('unused_inline_rule_provider_settings', path);
            }
            if (value['payload'] is! List) throw const FormatException();
            inline[entry.key] = List<dynamic>.from(value['payload']);
          } else if (type == 'http' || type == 'file') {
            if (value.containsKey('payload')) {
              issue('rule_provider_bootstrap_not_supported', path);
            }
            final uri = type == 'http'
                ? Uri.tryParse(text(value['url']))
                : null;
            if (type == 'http' &&
                (uri == null ||
                    !const {'http', 'https'}.contains(uri.scheme) ||
                    uri.host.isEmpty ||
                    uri.userInfo.isNotEmpty ||
                    uri.hasFragment)) {
              throw const FormatException();
            }
            if (type == 'file' &&
                (local == null ||
                    value.keys.any(
                      (key) => const {'url', 'proxy'}.contains(key),
                    ))) {
              throw const FormatException();
            }
            if (type == 'http' && local != null) {
              issue(
                'rule_provider_cache_path_client_owned',
                path,
                warning: true,
              );
            }
            requests.add(
              CoreRuleProviderRequest(
                name: entry.key,
                index: index,
                url: uri,
                path: local,
                outbound: value['proxy'] == null ? null : text(value['proxy']),
                behavior: behavior,
                format: format,
                interval: Duration(seconds: interval),
                timeout: timeout,
                maxBytes: payloadLimit,
              ),
            );
          } else {
            issue('unsupported_rule_provider_type', path);
          }
        } on FormatException {
          issue('invalid_rule_provider', path);
        }
        index++;
      }
    } on JsonUnsupportedObjectError {
      issue('invalid_rule_providers', 'rule-providers');
    } on FormatException {
      issue('invalid_rule_providers', 'rule-providers');
    }
    return _RulePlan(document, requests, inline, behaviors, issues);
  }

  ExpandedClashRules expand(_RulePlan plan, Map<String, String> payloads) {
    final entries = <String, List<String>>{};
    var count = 0;
    final names = plan.behaviors.keys.toList();
    for (var index = 0; index < names.length; index++) {
      final name = names[index];
      final path = 'rule-providers.$index';
      try {
        List<dynamic> raw;
        if (plan.inline.containsKey(name)) {
          raw = plan.inline[name]!;
        } else {
          final request = plan.requests.singleWhere(
            (request) => request.name == name,
          );
          final payload = payloads[name]!;
          if (request.format == 'yaml') {
            final parsed = map(decodeCoreYaml(payload));
            if (parsed.length != 1 || parsed['payload'] is! List) {
              throw const FormatException();
            }
            raw = parsed['payload'] as List;
          } else {
            raw = const LineSplitter()
                .convert(payload)
                .map((line) => line.trim())
                .where((line) => line.isNotEmpty && !line.startsWith('#'))
                .toList();
          }
        }
        count += raw.length;
        if (count > ruleLimit) throw const FormatException();
        final converted = <String>[];
        for (var row = 0; row < raw.length; row++) {
          try {
            final entry = text(raw[row]).trim();
            if (plan.behaviors[name] == 'domain') {
              final suffix = entry.startsWith('+.');
              final domain = suffix ? entry.substring(2) : entry;
              if (!_domain(domain)) throw const FormatException();
              converted.add('${suffix ? 'DOMAIN-SUFFIX' : 'DOMAIN'},$domain');
            } else if (plan.behaviors[name] == 'ipcidr') {
              if (CoreIpPrefix.parse(entry) == null) {
                throw const FormatException();
              }
              converted.add(
                '${entry.contains(':') ? 'IP-CIDR6' : 'IP-CIDR'},$entry',
              );
            } else {
              final fields = entry
                  .split(',')
                  .map((part) => part.trim())
                  .toList();
              final ip =
                  fields.first == 'IP-CIDR' || fields.first == 'IP-CIDR6';
              final geo = fields.first == 'GEOIP' || fields.first == 'GEOSITE';
              if (geo) {
                final geoIp = fields.first == 'GEOIP';
                if ((fields.length != 2 &&
                        !(geoIp &&
                            fields.length == 3 &&
                            fields.last == 'no-resolve')) ||
                    CoreGeoRequest.parse(
                          geoIp ? CoreGeoKind.ip : CoreGeoKind.site,
                          fields[1],
                        ) ==
                        null) {
                  throw const FormatException();
                }
                converted.add(fields.join(','));
                continue;
              }
              if (ip) {
                if ((fields.length != 2 &&
                        !(fields.length == 3 && fields.last == 'no-resolve')) ||
                    CoreIpPrefix.parse(fields[1]) == null) {
                  throw const FormatException();
                }
                converted.add(fields.join(','));
                continue;
              }
              if (fields.length != 2 ||
                  !const {
                    'DOMAIN',
                    'DOMAIN-SUFFIX',
                    'DOMAIN-KEYWORD',
                  }.contains(fields[0]) ||
                  (fields[0] == 'DOMAIN-KEYWORD'
                      ? fields[1].isEmpty
                      : !_domain(fields[1]))) {
                throw const FormatException();
              }
              converted.add(fields.join(','));
            }
          } on FormatException {
            issue('unsupported_rule_provider_entry', '$path.payload.$row');
          }
        }
        entries[name] = converted;
      } on YamlException {
        issue('invalid_rule_provider_payload', path);
      } on FormatException {
        issue('invalid_rule_provider_payload', path);
      }
    }
    final rules = <String>[];
    var expandedBytes = 0;
    bool appendParts(List<String> parts, String path) {
      var bytes = parts.length;
      for (final part in parts) {
        if (part.length > CoreConfigEncoding.maxBytes - expandedBytes - bytes) {
          issue('expanded_rule_size_exceeded', path);
          return false;
        }
        bytes += utf8.encode(part).length;
        if (bytes > CoreConfigEncoding.maxBytes - expandedBytes) {
          issue('expanded_rule_size_exceeded', path);
          return false;
        }
      }
      expandedBytes += bytes;
      rules.add(parts.join(','));
      return true;
    }

    final input = plan.document['rules'];
    var finalSeen = false;
    if (input is! List) {
      issue('invalid_rules', 'rules');
    } else {
      rulesLoop:
      for (var index = 0; index < input.length; index++) {
        final path = 'rules.$index';
        try {
          final rule = text(input[index]);
          final fields = rule.split(',').map((part) => part.trim()).toList();
          if (finalSeen) {
            issue('rule_after_final', path);
            continue;
          }
          if (fields.first == 'MATCH') finalSeen = true;
          if (fields.first == 'RULE-SET') {
            final noResolve = fields.length == 4 && fields.last == 'no-resolve';
            if ((fields.length != 3 && !noResolve) ||
                fields[2].isEmpty ||
                !entries.containsKey(fields[1])) {
              issue('invalid_rule_set_reference', path);
              continue;
            }
            if (rules.length + entries[fields[1]]!.length > ruleLimit) {
              issue('expanded_rule_limit_exceeded', path);
              break;
            }
            if (plan.behaviors[fields[1]] == 'ipcidr' &&
                !noResolve &&
                entries[fields[1]]!.isEmpty) {
              issue('empty_resolving_rule_set_not_migrated', path);
              continue;
            }
            for (final entry in entries[fields[1]]!) {
              final parts = entry.split(',');
              final ip =
                  parts.first == 'IP-CIDR' ||
                  parts.first == 'IP-CIDR6' ||
                  parts.first == 'GEOIP';
              if (ip) {
                if (!appendParts([
                  parts[0],
                  parts[1],
                  fields[2],
                  if (noResolve || parts.length == 3) 'no-resolve',
                ], path)) {
                  break rulesLoop;
                }
              } else {
                if (!appendParts([entry, fields[2]], path)) break rulesLoop;
              }
            }
          } else {
            if (rules.length >= ruleLimit) {
              issue('expanded_rule_limit_exceeded', path);
              break;
            }
            if (!appendParts([rule], path)) break rulesLoop;
          }
        } on FormatException {
          issue('invalid_rule', path);
        }
      }
    }
    final document = {...plan.document}..remove('rule-providers');
    document['rules'] = rules;
    return ExpandedClashRules(
      _errors(issues) ? null : document,
      issues,
      counts: entries.map((key, value) => MapEntry(key, value.length)),
    );
  }
}

bool _domain(String value) =>
    value.length <= 253 &&
    value.isNotEmpty &&
    value
        .split('.')
        .every(
          (label) =>
              label.isNotEmpty &&
              label.length <= 63 &&
              RegExp(
                r'^[a-zA-Z0-9_](?:[a-zA-Z0-9_-]*[a-zA-Z0-9_])?$',
              ).hasMatch(label),
        );

import 'dart:convert';
import 'dart:isolate';

import 'package:yaml/yaml.dart';

import 'clash_importer.dart';
import 'profile.dart';

enum CoreProxyProviderKind { http, file }

final class CoreProxyProviderRequest {
  final int index;
  final String name;
  final CoreProxyProviderKind kind;
  final Uri? url;
  final String? path;
  final String? outbound;
  final Duration interval;
  final Duration timeout;
  final int maxBytes;
  final Map<String, List<String>> headers;

  CoreProxyProviderRequest({
    required this.index,
    required this.name,
    required this.kind,
    required this.url,
    required this.path,
    required this.outbound,
    required this.interval,
    required this.timeout,
    required this.maxBytes,
    required Map<String, List<String>> headers,
  }) : headers = Map.unmodifiable(
         headers.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       );
}

// Resolvers enforce the byte limit while reading and own file/route authorization.
typedef CoreProxyProviderResolver =
    Future<String> Function(CoreProxyProviderRequest request);

final class ClashProviderPlan {
  final List<CoreProxyProviderRequest> requests;
  final List<CoreConfigIssue> issues;
  final Map<String, dynamic> _document;
  final Map<String, List<dynamic>> _inline;
  final Map<String, String> _healthUrls;

  ClashProviderPlan._(
    this._document,
    this._inline,
    this._healthUrls,
    List<CoreProxyProviderRequest> requests,
    List<CoreConfigIssue> issues,
  ) : requests = List.unmodifiable(requests),
      issues = List.unmodifiable(issues);
}

final class ClashSubscriptionImporter {
  final CoreProxyProviderResolver resolve;
  final int concurrency;
  final Duration timeout;

  ClashSubscriptionImporter({
    required this.resolve,
    this.concurrency = 4,
    this.timeout = const Duration(seconds: 20),
  }) {
    if (concurrency < 1 || concurrency > 16 || timeout <= Duration.zero) {
      throw ArgumentError('Invalid provider resolution bounds');
    }
  }

  Future<ClashProviderPlan> plan(String source) {
    return _planProviders(source, timeout);
  }

  Future<CoreConfigImportResult> import(String source) async {
    final prepared = await plan(source);
    if (_hasErrors(prepared.issues)) {
      return CoreConfigImportResult(issues: prepared.issues);
    }
    final issues = [...prepared.issues];
    final payloads = <String, String>{};
    var next = 0;
    var totalBytes = 0;
    var aborted = false;
    Future<void> worker() async {
      while (!aborted && next < prepared.requests.length) {
        final request = prepared.requests[next++];
        final path = 'proxy-providers.${request.index}';
        try {
          final content = await resolve(request).timeout(timeout);
          if (content.length > request.maxBytes) {
            aborted = true;
            issues.add(CoreConfigIssue('provider_payload_too_large', path));
            continue;
          }
          final size = await _providerPayloadSize(content);
          if (size > request.maxBytes) {
            aborted = true;
            issues.add(CoreConfigIssue('provider_payload_too_large', path));
          } else if ((totalBytes += size) > _ProviderImport.totalLimit) {
            aborted = true;
            issues.add(CoreConfigIssue('provider_total_size_exceeded', path));
          } else {
            payloads[request.name] = content;
          }
        } catch (_) {
          aborted = true;
          issues.add(CoreConfigIssue('provider_resolution_failed', path));
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    if (_hasErrors(issues)) return CoreConfigImportResult(issues: issues);
    final expanded = await _expandProviders(prepared, payloads);
    issues.addAll(expanded.issues);
    if (_hasErrors(issues)) return CoreConfigImportResult(issues: issues);
    final imported = await ClashProfileImporter().importDocument(
      expanded.document,
    );
    for (final issue in imported.issues) {
      final match = RegExp(r'^proxies\.(\d+)(.*)$').firstMatch(issue.path);
      final index = match == null ? null : int.tryParse(match[1]!);
      final path = index != null && index < expanded.origins.length
          ? '${expanded.origins[index]}${match![2]}'
          : issue.path;
      issues.add(CoreConfigIssue(issue.code, path, severity: issue.severity));
    }
    return CoreConfigImportResult(profile: imported.profile, issues: issues);
  }
}

bool _hasErrors(List<CoreConfigIssue> issues) =>
    issues.any((issue) => issue.severity == CoreConfigIssueSeverity.error);

Future<ClashProviderPlan> _planProviders(String source, Duration timeout) =>
    Isolate.run(() => _ProviderImport().plan(source, timeout));

Future<int> _providerPayloadSize(String content) =>
    Isolate.run(() => utf8.encode(content).length);

Future<_ExpandedClash> _expandProviders(
  ClashProviderPlan prepared,
  Map<String, String> payloads,
) => Isolate.run(() => _ProviderImport().expand(prepared, payloads));

List<String> _sortedNames(Iterable<String> names) {
  // Go sorts UTF-8 bytes; preserving that order also preserves default selection.
  final encoded = [for (final name in names) (name, utf8.encode(name))];
  encoded.sort((a, b) {
    final length = a.$2.length < b.$2.length ? a.$2.length : b.$2.length;
    for (var i = 0; i < length; i++) {
      final compared = a.$2[i].compareTo(b.$2[i]);
      if (compared != 0) return compared;
    }
    return a.$2.length.compareTo(b.$2.length);
  });
  return [for (final entry in encoded) entry.$1];
}

final class _ExpandedClash {
  final Map<String, dynamic> document;
  final List<String> origins;
  final List<CoreConfigIssue> issues;

  const _ExpandedClash(this.document, this.origins, this.issues);
}

final class _ProviderImport {
  static const payloadLimit = 16 * 1024 * 1024;
  static const totalLimit = 32 * 1024 * 1024;
  static const nodeLimit = 100000;
  static const membershipLimit = 250000;
  final List<CoreConfigIssue> issues = [];

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

  List<dynamic> list(Object? value) {
    if (value is! List) throw const FormatException();
    return value;
  }

  String text(Object? value) {
    if (value is! String || value.isEmpty) throw const FormatException();
    return value;
  }

  bool flag(Object? value) {
    if (value == null) return false;
    if (value is! bool) throw const FormatException();
    return value;
  }

  int integer(Object? value, int fallback) {
    if (value == null) return fallback;
    if (value is! int || value < 0) throw const FormatException();
    return value;
  }

  ClashProviderPlan plan(String source, Duration timeout) {
    final requests = <CoreProxyProviderRequest>[];
    final inline = <String, List<dynamic>>{};
    final urls = <String, String>{};
    var root = <String, dynamic>{};
    try {
      if (source.length > payloadLimit ||
          utf8.encode(source).length > payloadLimit) {
        throw const FormatException();
      }
      root = map(loadYaml(source));
      final providers = map(root['proxy-providers'] ?? <String, dynamic>{});
      if (providers.length > 64) throw const FormatException();
      var index = 0;
      for (final entry in providers.entries) {
        final path = 'proxy-providers.$index';
        try {
          text(entry.key);
          final provider = map(entry.value);
          final type = text(provider['type']);
          for (final key in provider.keys) {
            if (!const {
              'type',
              'url',
              'path',
              'proxy',
              'interval',
              'header',
              'health-check',
              'size-limit',
              'payload',
            }.contains(key)) {
              issue('unsupported_provider_field', path);
            }
          }
          final interval = Duration(seconds: integer(provider['interval'], 0));
          final requestedLimit = integer(provider['size-limit'], 0);
          final maxBytes = requestedLimit == 0 || requestedLimit > payloadLimit
              ? payloadLimit
              : requestedLimit;
          if (requestedLimit > payloadLimit) {
            issue('provider_size_limit_capped', path, warning: true);
          }
          final headers = <String, List<String>>{};
          for (final header in map(
            provider['header'] ?? <String, dynamic>{},
          ).entries) {
            if (!RegExp(
              r'''^[!#$%&'*+.^_`|~0-9A-Za-z-]+$''',
            ).hasMatch(header.key)) {
              throw const FormatException();
            }
            final values = list(header.value).map(text).toList();
            if (values.any((value) => value.contains(RegExp(r'[\r\n]')))) {
              throw const FormatException();
            }
            headers[header.key] = values;
          }
          if (provider['health-check'] != null) {
            final health = map(provider['health-check']);
            for (final key in health.keys) {
              if (!const {
                'enable',
                'url',
                'interval',
                'timeout',
                'lazy',
                'expected-status',
              }.contains(key)) {
                issue('unsupported_provider_health_check_field', path);
              }
            }
            if (health['url'] != null) urls[entry.key] = text(health['url']);
            integer(health['interval'], 0);
            integer(health['timeout'], 0);
            flag(health['lazy']);
            if (health['expected-status'] != null) {
              text(health['expected-status']);
            }
            if (flag(health['enable']) ||
                health.keys.any((key) => key != 'enable')) {
              issue('provider_health_check_not_migrated', path, warning: true);
            }
          }
          final localPath = provider['path'] == null
              ? null
              : text(provider['path']);
          if (localPath != null &&
              (localPath.startsWith(RegExp(r'[/\\]')) ||
                  localPath.contains(':') ||
                  localPath.split(RegExp(r'[/\\]')).contains('..'))) {
            throw const FormatException();
          }
          if (type == 'inline') {
            if (provider.keys.any(
              (key) => const {
                'url',
                'path',
                'proxy',
                'interval',
                'header',
                'size-limit',
              }.contains(key),
            )) {
              issue('unused_inline_provider_settings', path);
            }
            inline[entry.key] = list(provider['payload']);
          } else if (type == 'http' || type == 'file') {
            if (provider.containsKey('payload')) {
              issue('provider_bootstrap_payload_not_supported', path);
            }
            final url = type == 'http'
                ? Uri.tryParse(text(provider['url']))
                : null;
            if (type == 'http' &&
                    (url == null ||
                        !const ['http', 'https'].contains(url.scheme) ||
                        url.host.isEmpty ||
                        url.hasFragment) ||
                type == 'file' && localPath == null) {
              throw const FormatException();
            }
            if (type == 'file' &&
                provider.keys.any(
                  (key) => const {'url', 'header', 'proxy'}.contains(key),
                )) {
              issue('unused_file_provider_settings', path);
            }
            if (type == 'http' && localPath != null) {
              issue('provider_cache_path_client_owned', path, warning: true);
            }
            requests.add(
              CoreProxyProviderRequest(
                index: index,
                name: entry.key,
                kind: type == 'http'
                    ? CoreProxyProviderKind.http
                    : CoreProxyProviderKind.file,
                url: url,
                path: localPath,
                outbound: provider['proxy'] == null
                    ? null
                    : text(provider['proxy']),
                interval: interval,
                timeout: timeout,
                maxBytes: maxBytes,
                headers: headers,
              ),
            );
          } else {
            issue('unsupported_provider_type', path);
          }
        } on FormatException {
          issue('invalid_provider_value', path);
        }
        index++;
      }
    } on YamlException {
      issue('invalid_yaml', 'document');
    } on FormatException {
      issue('invalid_provider_document', 'document');
    }
    return ClashProviderPlan._(root, inline, urls, requests, issues);
  }

  _ExpandedClash expand(ClashProviderPlan plan, Map<String, String> payloads) {
    final root = Map<String, dynamic>.of(plan._document);
    final origins = <String>[];
    try {
      final nodes = List<dynamic>.of(list(root['proxies'] ?? []));
      if (nodes.length > nodeLimit) {
        issue('provider_node_limit_exceeded', 'proxies');
        return _ExpandedClash(root, origins, issues);
      }
      final names = <String>{};
      for (var i = 0; i < nodes.length; i++) {
        final name = text(map(nodes[i])['name']);
        if (!names.add(name)) issue('duplicate_node_tag', 'proxies.$i');
        origins.add('proxies.$i');
      }
      final rootNames = _sortedNames(names);
      final memberships = <String, List<String>>{};
      final declarations = map(
        root.remove('proxy-providers') ?? <String, dynamic>{},
      );
      var providerIndex = 0;
      for (final name in declarations.keys) {
        final path = 'proxy-providers.$providerIndex';
        final members = <String>[];
        try {
          List<dynamic> entries;
          if (plan._inline.containsKey(name)) {
            entries = plan._inline[name]!;
          } else {
            final content = payloads[name]!;
            final document = map(loadYaml(content));
            if (document.keys.any((key) => key != 'proxies')) {
              issue('unexpected_provider_payload_fields', path);
            }
            entries = list(document['proxies']);
          }
          if (entries.isEmpty) issue('empty_provider', path);
          if (nodes.length + entries.length > nodeLimit) {
            issue('provider_node_limit_exceeded', path);
            return _ExpandedClash(root, origins, issues);
          }
          for (var i = 0; i < entries.length; i++) {
            final node = map(entries[i]);
            final tag = text(node['name']);
            if (!names.add(tag)) {
              issue('duplicate_node_tag', '$path.payload.$i');
            }
            members.add(tag);
            nodes.add(node);
            origins.add('$path.payload.$i');
          }
        } on YamlException {
          issue('invalid_provider_yaml', path);
        } on FormatException {
          issue('invalid_provider_payload', path);
        }
        memberships[name] = members;
        providerIndex++;
      }
      final allProviders = _sortedNames(memberships.keys);
      final groups = list(root['proxy-groups'] ?? []);
      final expandedGroups = <Map<String, dynamic>>[];
      var totalMemberships = 0;
      for (var i = 0; i < groups.length; i++) {
        final path = 'proxy-groups.$i';
        try {
          final group = map(groups[i]);
          final includeAll = flag(group.remove('include-all'));
          final includeProviders =
              flag(group.remove('include-all-providers')) || includeAll;
          final includeProxies =
              flag(group.remove('include-all-proxies')) || includeAll;
          final use = group.remove('use');
          final selectedProviders = includeProviders
              ? allProviders
              : (use == null ? <String>[] : list(use).map(text).toList());
          final explicit = list(group['proxies'] ?? []).map(text).toList();
          final memberCount =
              explicit.length +
              (includeProxies ? rootNames.length : 0) +
              selectedProviders.fold<int>(
                0,
                (sum, name) => sum + (memberships[name]?.length ?? 0),
              );
          totalMemberships += memberCount;
          if (totalMemberships > membershipLimit) {
            issue('expanded_membership_limit_exceeded', path);
            return _ExpandedClash(root, origins, issues);
          }
          final members = <String>[
            ...explicit,
            if (includeProxies) ...rootNames,
          ];
          for (final provider in selectedProviders) {
            final provided = memberships[provider];
            if (provided == null) {
              issue('unknown_provider_reference', '$path.use');
            } else {
              members.addAll(provided);
            }
          }
          final distinct = members.toSet().toList();
          if (members.length != distinct.length) {
            issue('duplicate_group_member_collapsed', path, warning: true);
          }
          if (distinct.isEmpty) issue('empty_expanded_group', path);
          group['proxies'] = distinct;
          if (group['url'] == null &&
              const ['url-test', 'fallback'].contains(group['type'])) {
            for (final provider in selectedProviders) {
              if (plan._healthUrls.containsKey(provider)) {
                group['url'] = plan._healthUrls[provider];
                break;
              }
            }
          }
          expandedGroups.add(group);
        } on FormatException {
          issue('invalid_provider_group', path);
        }
      }
      root['proxies'] = nodes;
      root['proxy-groups'] = expandedGroups;
    } on FormatException {
      issue('invalid_provider_document', 'document');
    }
    return _ExpandedClash(root, origins, issues);
  }
}

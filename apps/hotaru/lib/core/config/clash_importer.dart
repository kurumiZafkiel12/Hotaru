import 'dart:isolate';

import 'package:yaml/yaml.dart';

import 'clash_dns.dart';
import 'encoding.dart';
import 'geodata.dart';
import 'ip_prefix.dart';
import 'profile.dart';
import 'rule_set.dart';
import 'yaml_document.dart';

final class ClashProfileImporter {
  Future<List<CoreNodeImportResult>> importNodes(
    List<Map<String, dynamic>> nodes,
  ) => Isolate.run(() {
    if (nodes.length > 100000) throw const CoreConfigSizeException();
    CoreConfigEncoding.encode(nodes);
    return [
      for (var index = 0; index < nodes.length; index++)
        _importNode(nodes[index], 'proxies.$index'),
    ];
  });

  static CoreNodeImportResult _importNode(
    Map<String, dynamic> node,
    String path,
  ) {
    final reader = _ClashImport();
    final result = reader.tryReadNode(node, path);
    return CoreNodeImportResult(result, reader.issues);
  }

  Future<CoreConfigImportResult> import(
    String source, {
    CoreGeoResolver? resolveGeo,
  }) {
    if (resolveGeo != null) {
      return _withGeo(
        () => Isolate.run(() => _ClashImport().map(decodeCoreYaml(source))),
        resolveGeo,
      );
    }
    return Isolate.run(() => _ClashImport().read(source));
  }

  Future<CoreConfigImportResult> importDocument(
    Map<String, dynamic> document, {
    CoreGeoResolver? resolveGeo,
  }) {
    if (resolveGeo != null) return _withGeo(() async => document, resolveGeo);
    return Isolate.run(() => _ClashImport().readDocument(document));
  }
}

Future<CoreConfigImportResult> _withGeo(
  Future<Map<String, dynamic>> Function() read,
  CoreGeoResolver resolve,
) async {
  final Map<String, dynamic> document;
  try {
    document = await read();
  } on YamlException {
    return CoreConfigImportResult(
      issues: [const CoreConfigIssue('invalid_yaml', 'document')],
    );
  } on Exception {
    return CoreConfigImportResult(
      issues: [const CoreConfigIssue('invalid_document_value', 'document')],
    );
  }
  try {
    final requests = await Isolate.run(() {
      final requests = <String, CoreGeoRequest>{};
      final rules = document['rules'];
      if (rules is List) {
        for (final rule in rules) {
          if (rule is! String) continue;
          final parts = rule.split(',').map((value) => value.trim()).toList();
          if (parts.length < 3) continue;
          final kind = switch (parts.first) {
            'GEOIP' => CoreGeoKind.ip,
            'GEOSITE' => CoreGeoKind.site,
            _ => null,
          };
          if (kind == null) continue;
          final request = CoreGeoRequest.parse(kind, parts[1]);
          if (request != null && builtinCoreGeoMatch(request) == null) {
            requests[request.key] = request;
          }
          if (requests.length > 1024) {
            throw const FormatException('geo_request_limit');
          }
        }
      }
      return List<CoreGeoRequest>.unmodifiable(requests.values);
    });
    final data = requests.isEmpty
        ? const <String, CoreGeoMatchData>{}
        : await resolve(requests);
    final expected = {for (final request in requests) request.key};
    if (data.length > expected.length ||
        data.keys.any((key) => !expected.contains(key))) {
      throw const FormatException('invalid_geo_resolution');
    }
    return await Isolate.run(
      () => _ClashImport(geodata: data).readDocument(document),
    );
  } catch (_) {
    return CoreConfigImportResult(
      issues: [const CoreConfigIssue('geo_data_resolution_failed', 'geodata')],
    );
  }
}

final class _ClashImport {
  final List<CoreConfigIssue> issues = [];
  final Map<String, CoreGeoMatchData> geodata;

  _ClashImport({this.geodata = const {}});

  void issue(String code, String path, {bool warning = false}) {
    issues.add(
      CoreConfigIssue(
        code,
        path,
        severity: warning
            ? CoreConfigIssueSeverity.warning
            : CoreConfigIssueSeverity.error,
      ),
    );
  }

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
    if (value is! String) throw const FormatException();
    return value;
  }

  String? optionalText(Object? value) => value == null ? null : text(value);

  int number(Object? value) {
    if (value is String && RegExp(r'^[0-9]+$').hasMatch(value)) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
    if (value is! int) throw const FormatException();
    return value;
  }

  bool boolean(Object? value, {bool fallback = false}) {
    if (value == null) return fallback;
    if (value is! bool) throw const FormatException();
    return value;
  }

  void keys(Map<String, dynamic> value, Set<String> allowed, String path) {
    for (final key in value.keys) {
      if (!allowed.contains(key)) issue('unsupported_field', '$path.$key');
    }
  }

  CoreConfigImportResult read(String source) {
    try {
      return readDocument(map(decodeCoreYaml(source)));
    } on YamlException {
      issue('invalid_yaml', 'document');
    } on FormatException {
      issue('invalid_document_value', 'document');
    }
    return CoreConfigImportResult(issues: issues);
  }

  CoreConfigImportResult readDocument(Map<String, dynamic> input) {
    try {
      final geoMode = boolean(input['geodata-mode']);
      for (final key in input.keys) {
        if (key.startsWith('x-')) {
          issue('metadata_field_ignored', 'document.$key', warning: true);
          continue;
        }
        if (key == 'dns') continue;
        if (key == 'geodata-mode') continue;
        if (key == 'geodata-loader') {
          if (!['standard', 'memconservative', 'memc'].contains(input[key])) {
            issue('unsupported_geodata_loader', key);
          } else {
            issue('app_owned_setting_replaced', key, warning: true);
          }
          continue;
        }
        if (const ['proxies', 'proxy-groups', 'rules'].contains(key)) continue;
        if (const [
          'mixed-port',
          'port',
          'socks-port',
          'allow-lan',
          'bind-address',
          'external-controller',
          'secret',
          'log-level',
        ].contains(key)) {
          issue('app_owned_setting_replaced', key, warning: true);
        } else if (key == 'mode' && input[key] == 'rule') {
          continue;
        } else {
          issue(switch (key) {
            'proxy-providers' => 'provider_expansion_required',
            'rule-providers' => 'rule_provider_conversion_required',
            _ => 'unsupported_field',
          }, key);
        }
      }
      final nodes = <CoreNodeSpec>[];
      final CoreDnsImportResult? dns = input['dns'] == null
          ? null
          : importClashDns(input['dns']);
      if (dns != null) issues.addAll(dns.issues);
      final rawNodes = list(input['proxies'] ?? []);
      for (var index = 0; index < rawNodes.length; index++) {
        final path = 'proxies.$index';
        final node = tryReadNode(rawNodes[index], path);
        if (node != null) nodes.add(node);
      }
      final selectors = <CoreSelectorSpec>[];
      final rawGroups = list(input['proxy-groups'] ?? []);
      for (var index = 0; index < rawGroups.length; index++) {
        final path = 'proxy-groups.$index';
        try {
          final group = readGroup(map(rawGroups[index]), path);
          if (group != null) selectors.add(group);
        } on FormatException {
          issue('invalid_group_value', path);
        }
      }
      final rules = <CoreRouteRule>[];
      final ruleSets = <String, CoreRuleSetSpec>{};
      String? finalOutbound;
      final rawRules = list(input['rules'] ?? []);
      for (var index = 0; index < rawRules.length; index++) {
        final path = 'rules.$index';
        final fields = text(
          rawRules[index],
        ).split(',').map((part) => part.trim()).toList();
        if (finalOutbound != null) {
          issue('rule_after_final', path);
          continue;
        }
        if (fields.length == 2 && fields.first == 'MATCH') {
          finalOutbound = fields.last;
          if (const ['REJECT', 'REJECT-DROP'].contains(finalOutbound)) {
            rules.add(
              CoreRouteRule(
                kind: CoreRuleKind.always,
                value: '',
                action: finalOutbound == 'REJECT'
                    ? CoreRuleAction.reject
                    : CoreRuleAction.drop,
              ),
            );
            finalOutbound = 'DIRECT';
          }
          continue;
        }
        if (fields.first == 'GEOIP' || fields.first == 'GEOSITE') {
          final geoIp = fields.first == 'GEOIP';
          final noResolve =
              geoIp && fields.length == 4 && fields.last == 'no-resolve';
          if (fields.length != 3 && !noResolve) {
            issue('unsupported_rule', path);
            continue;
          }
          final request = CoreGeoRequest.parse(
            geoIp ? CoreGeoKind.ip : CoreGeoKind.site,
            fields[1],
          );
          final builtin = request == null ? null : builtinCoreGeoMatch(request);
          final data = request == null ? null : builtin ?? geodata[request.key];
          if (data == null) {
            issue(
              request == null ? 'invalid_geo_selector' : 'geo_data_required',
              path,
            );
            continue;
          }
          if (data.set.kind !=
              (geoIp ? CoreRuleSetKind.ipCidr : CoreRuleSetKind.domain)) {
            issue('invalid_geo_resolution', path);
            continue;
          }
          final previous = ruleSets[data.set.tag];
          if (previous != null && !identical(previous, data.set)) {
            issue('conflicting_geo_rule_set', path);
            continue;
          }
          ruleSets[data.set.tag] = data.set;
          if (geoIp && !geoMode && builtin == null) {
            issue('geoip_database_changed', path, warning: true);
          }
          if (geoIp && !noResolve) {
            issue('ip_resolution_semantics_changed', path, warning: true);
          }
          final action = switch (fields[2]) {
            'REJECT' => CoreRuleAction.reject,
            'REJECT-DROP' => CoreRuleAction.drop,
            _ => CoreRuleAction.route,
          };
          rules.add(
            CoreRouteRule(
              kind: CoreRuleKind.ruleSet,
              value: data.set.tag,
              outbound: action == CoreRuleAction.route ? fields[2] : null,
              action: action,
              noResolve: noResolve,
              invert: data.inverted,
            ),
          );
          continue;
        }
        final kind = switch (fields.first) {
          'DOMAIN' => CoreRuleKind.domain,
          'DOMAIN-SUFFIX' => CoreRuleKind.domainSuffix,
          'DOMAIN-KEYWORD' => CoreRuleKind.domainKeyword,
          'IP-CIDR' || 'IP-CIDR6' => CoreRuleKind.ipCidr,
          _ => null,
        };
        final ip = kind == CoreRuleKind.ipCidr;
        final noResolve =
            ip && fields.length == 4 && fields.last == 'no-resolve';
        if (kind == null || (fields.length != 3 && !noResolve)) {
          issue('unsupported_rule', path);
          continue;
        }
        if (ip && !noResolve) {
          issue('ip_resolution_semantics_changed', path, warning: true);
        }
        if (ip && CoreIpPrefix.parse(fields[1]) == null) {
          issue('invalid_ip_prefix', path);
          continue;
        }
        final action = switch (fields[2]) {
          'REJECT' => CoreRuleAction.reject,
          'REJECT-DROP' => CoreRuleAction.drop,
          _ => CoreRuleAction.route,
        };
        rules.add(
          CoreRouteRule(
            kind: kind,
            value: fields[1],
            noResolve: noResolve,
            action: action,
            outbound: action == CoreRuleAction.route ? fields[2] : null,
          ),
        );
      }
      if (finalOutbound == null) {
        issue('explicit_final_required', 'rules');
      }
      final references = <String>{
        ?finalOutbound,
        for (final group in selectors) ...group.members,
        for (final rule in rules) ?rule.outbound,
      };
      if (references.contains('DIRECT')) {
        if (nodes.any((node) => node.tag == 'DIRECT') ||
            selectors.any((group) => group.tag == 'DIRECT')) {
          issue('reserved_direct_tag', 'proxies');
        } else {
          nodes.add(
            const CoreNodeSpec(
              tag: 'DIRECT',
              protocol: CoreNodeProtocol.direct,
            ),
          );
        }
      }
      if (references.contains('REJECT') || references.contains('REJECT-DROP')) {
        issue('reject_group_member_requires_client_policy', 'proxy-groups');
      }
      return CoreConfigImportResult(
        profile:
            issues.any((item) => item.severity == CoreConfigIssueSeverity.error)
            ? null
            : CoreProfileSpec(
                nodes: nodes,
                selectors: selectors,
                finalOutbound: finalOutbound!,
                rules: rules,
                ruleSets: ruleSets.values.toList(),
                dns: dns?.dns,
              ),
        issues: issues,
      );
    } on YamlException {
      issue('invalid_yaml', 'document');
    } on FormatException {
      issue('invalid_document_value', 'document');
    }
    return CoreConfigImportResult(issues: issues);
  }

  CoreNodeSpec? tryReadNode(Object? value, String path) {
    try {
      return readNode(map(value), path);
    } on FormatException {
      issue('invalid_node_value', path);
      return null;
    }
  }

  CoreNodeSpec? readNode(Map<String, dynamic> node, String path) {
    final protocol = switch (node['type']) {
      'direct' => CoreNodeProtocol.direct,
      'http' => CoreNodeProtocol.http,
      'socks5' => CoreNodeProtocol.socks,
      'ss' => CoreNodeProtocol.shadowsocks,
      'vmess' => CoreNodeProtocol.vmess,
      'vless' => CoreNodeProtocol.vless,
      'trojan' => CoreNodeProtocol.trojan,
      'hysteria2' => CoreNodeProtocol.hysteria2,
      'tuic' => CoreNodeProtocol.tuic,
      _ => null,
    };
    if (protocol == null) {
      issue('unsupported_protocol', '$path.type');
      return null;
    }
    final allowed = <String>{'name', 'type'};
    if (protocol != CoreNodeProtocol.direct) {
      allowed.addAll(['server', 'port', 'udp', 'dialer-proxy']);
    }
    switch (protocol) {
      case CoreNodeProtocol.direct:
        break;
      case CoreNodeProtocol.http:
        allowed.addAll(['username', 'password']);
      case CoreNodeProtocol.socks:
        allowed.addAll(['username', 'password']);
      case CoreNodeProtocol.shadowsocks:
        allowed.addAll(['password', 'cipher']);
      case CoreNodeProtocol.vmess:
        allowed.addAll(['uuid', 'cipher', 'alterId']);
      case CoreNodeProtocol.vless:
        allowed.addAll(['uuid', 'flow', 'encryption']);
      case CoreNodeProtocol.trojan:
        allowed.add('password');
      case CoreNodeProtocol.hysteria2:
        allowed.addAll(['password', 'up', 'down', 'obfs', 'obfs-password']);
      case CoreNodeProtocol.tuic:
        allowed.addAll([
          'uuid',
          'password',
          'congestion-controller',
          'udp-relay-mode',
        ]);
    }
    final tlsSupported = !const [
      CoreNodeProtocol.direct,
      CoreNodeProtocol.socks,
      CoreNodeProtocol.shadowsocks,
    ].contains(protocol);
    if (tlsSupported) {
      allowed.addAll([
        'tls',
        'servername',
        'sni',
        'skip-cert-verify',
        'alpn',
        'client-fingerprint',
      ]);
    }
    if (const [
      CoreNodeProtocol.vmess,
      CoreNodeProtocol.vless,
      CoreNodeProtocol.trojan,
    ].contains(protocol)) {
      allowed.addAll(['network', 'ws-opts', 'grpc-opts']);
    }
    if (protocol == CoreNodeProtocol.vless) allowed.add('reality-opts');
    keys(node, allowed, path);
    if (node['udp'] != null) boolean(node['udp']);
    if (node['encryption'] != null &&
        node['encryption'] != '' &&
        node['encryption'] != 'none') {
      issue('unsupported_vless_encryption', '$path.encryption');
    }
    if (protocol == CoreNodeProtocol.http && boolean(node['udp'])) {
      issue('unsupported_http_udp', '$path.udp');
    }
    final defaultTls = const [
      CoreNodeProtocol.trojan,
      CoreNodeProtocol.hysteria2,
      CoreNodeProtocol.tuic,
    ].contains(protocol);
    final hasTls = boolean(node['tls'], fallback: defaultTls);
    if (!hasTls &&
        node.keys.any(
          (key) => const [
            'sni',
            'servername',
            'skip-cert-verify',
            'alpn',
            'client-fingerprint',
            'reality-opts',
          ].contains(key),
        )) {
      issue('tls_fields_without_tls', path);
    }
    final reality = node['reality-opts'] == null
        ? null
        : map(node['reality-opts']);
    if (reality != null) {
      keys(reality, {'public-key', 'short-id'}, '$path.reality-opts');
      if (optionalText(reality['public-key'])?.isNotEmpty != true) {
        issue('missing_reality_key', path);
      }
      if (optionalText(node['client-fingerprint'])?.isNotEmpty != true) {
        issue('reality_requires_fingerprint', path);
      }
    }
    if (node['sni'] != null &&
        node['servername'] != null &&
        node['sni'] != node['servername']) {
      issue('conflicting_server_name', path);
    }
    final tls = hasTls
        ? CoreTlsSpec(
            serverName: optionalText(node['servername'] ?? node['sni']),
            insecure: boolean(node['skip-cert-verify']),
            alpn: node['alpn'] == null
                ? []
                : list(node['alpn']).map(text).toList(),
            fingerprint: optionalText(node['client-fingerprint']),
            realityPublicKey: optionalText(reality?['public-key']),
            realityShortId: optionalText(reality?['short-id']),
          )
        : null;
    CoreTransportSpec? transport;
    final network = node['network'] ?? 'tcp';
    if (network == 'ws') {
      final ws = map(node['ws-opts'] ?? <String, dynamic>{});
      keys(ws, {'path', 'headers'}, '$path.ws-opts');
      transport = CoreTransportSpec(
        kind: CoreTransportKind.ws,
        path: optionalText(ws['path']),
        headers: ws['headers'] == null
            ? {}
            : map(
                ws['headers'],
              ).map((key, value) => MapEntry(key, text(value))),
      );
    } else if (network == 'grpc') {
      final grpc = map(node['grpc-opts'] ?? <String, dynamic>{});
      keys(grpc, {'grpc-service-name'}, '$path.grpc-opts');
      transport = CoreTransportSpec(
        kind: CoreTransportKind.grpc,
        serviceName: optionalText(grpc['grpc-service-name']),
      );
    } else if (network != 'tcp') {
      issue('unsupported_transport', '$path.network');
    }
    if (network != 'ws' && node.containsKey('ws-opts') ||
        network != 'grpc' && node.containsKey('grpc-opts')) {
      issue('transport_options_without_transport', path);
    }
    if (node['obfs'] != null && node['obfs'] != 'salamander' ||
        (node['obfs'] == null) != (node['obfs-password'] == null)) {
      issue('unsupported_obfuscation', path);
    }
    return CoreNodeSpec(
      tag: text(node['name']),
      protocol: protocol,
      server: optionalText(node['server']),
      port: node['port'] == null ? null : number(node['port']),
      detour: node['dialer-proxy'] == ''
          ? null
          : optionalText(node['dialer-proxy']),
      username: optionalText(node['username']),
      password: optionalText(node['password']),
      uuid: optionalText(node['uuid']),
      cipher: optionalText(node['cipher']),
      alterId: node['alterId'] == null ? null : number(node['alterId']),
      flow: optionalText(node['flow']),
      tls: tls,
      transport: transport,
      congestionControl: optionalText(node['congestion-controller']),
      udpRelayMode: optionalText(node['udp-relay-mode']),
      obfsPassword: optionalText(node['obfs-password']),
      upMbps: node['up'] == null ? null : number(node['up']),
      downMbps: node['down'] == null ? null : number(node['down']),
      tcpOnly: node['udp'] == false,
    );
  }

  CoreSelectorSpec? readGroup(Map<String, dynamic> group, String path) {
    keys(group, {
      'name',
      'type',
      'proxies',
      'url',
      'interval',
      'tolerance',
    }, path);
    final strategy = switch (group['type']) {
      'select' || 'load-balance' => CoreGroupStrategy.selector,
      'url-test' || 'fallback' => CoreGroupStrategy.urltest,
      _ => null,
    };
    if (strategy == null) {
      issue('unsupported_group', '$path.type');
      return null;
    }
    if (group['type'] == 'load-balance' || group['type'] == 'fallback') {
      issue(
        group['type'] == 'load-balance'
            ? 'load_balance_to_selector'
            : 'fallback_to_urltest',
        path,
        warning: true,
      );
    }
    if (strategy == CoreGroupStrategy.selector &&
        group.keys.any(
          (key) => const ['url', 'interval', 'tolerance'].contains(key),
        )) {
      issue('unused_group_test_settings', path, warning: true);
    }
    return CoreSelectorSpec(
      tag: text(group['name']),
      members: list(group['proxies']).map(text).toList(),
      strategy: strategy,
      testUrl:
          optionalText(group['url']) ?? 'https://www.gstatic.com/generate_204',
      interval: Duration(
        seconds: group['interval'] == null ? 300 : number(group['interval']),
      ),
      tolerance: group['tolerance'] == null ? 50 : number(group['tolerance']),
    );
  }
}

import 'dart:io';

import '../config/dns.dart';
import '../config/profile.dart';
import '../config/ip_prefix.dart';
import '../config/rule_set.dart';
import 'rule_sets_config.dart';

List<CoreConfigIssue> validateDns(
  CoreProfileSpec profile,
  CoreListenerSpec listeners,
) {
  final issues = <CoreConfigIssue>[];
  void error(String code, String path) =>
      issues.add(CoreConfigIssue(code, path));
  final dns = profile.dns;
  final port = listeners.dnsPort;
  if (port != null &&
      (port < 1 ||
          port > 65535 ||
          port == listeners.mixedPort ||
          port == listeners.controllerPort)) {
    error('invalid_dns_listener_port', 'listeners.dnsPort');
  }
  if (dns == null) {
    if (port != null ||
        listeners.tun?.hijackDns == true ||
        listeners.dnsGroups != null) {
      error('dns_required', 'listeners');
    }
    return issues;
  }
  final tags = <String>{};
  final outbounds = {
    ...profile.nodes.map((node) => node.tag),
    ...profile.selectors.map((group) => group.tag),
  };
  final graph = <String, List<String>>{};
  for (final server in dns.servers) {
    final path = 'dns.servers.${server.tag}';
    if (server.tag.isEmpty || !tags.add(server.tag)) {
      error('invalid_dns_tag', path);
    }
    if (server.protocol == CoreDnsProtocol.local) {
      if (server.server != null ||
          server.port != null ||
          server.path != null ||
          server.detour != null ||
          server.addressResolver != null) {
        error('invalid_local_dns_options', path);
      }
    } else {
      if (server.server == null ||
          server.server!.isEmpty ||
          server.server!.contains(RegExp(r'[\s\x00]')) ||
          server.port == null ||
          server.port! < 1 ||
          server.port! > 65535) {
        error('invalid_dns_server', path);
      }
      if (server.server != null &&
          InternetAddress.tryParse(server.server!) == null &&
          server.addressResolver == null) {
        error('dns_bootstrap_required', path);
      }
      if (server.protocol == CoreDnsProtocol.https) {
        if (server.path == null ||
            !server.path!.startsWith('/') ||
            server.path!.contains(RegExp(r'[?#\r\n]'))) {
          error('invalid_doh_path', path);
        }
      } else if (server.path != null) {
        error('unsupported_dns_path', path);
      }
    }
    if (server.detour != null && !outbounds.contains(server.detour)) {
      error('unknown_dns_detour', path);
    }
    graph['dns:${server.tag}'] = [
      if (server.addressResolver != null) 'dns:${server.addressResolver}',
      if (server.detour != null) 'out:${server.detour}',
    ];
  }
  final serverTags = Set<String>.of(tags);
  final ports = listeners.dnsGroups?.ports ?? const <String, int>{};
  final occupied = {
    ...listeners.dataPorts,
    listeners.controllerPort,
    ?listeners.dnsPort,
    ?listeners.probe?.port,
  };
  if (dns.groups.length > 16 || ports.length > 16) {
    error('dns_group_limit', 'dns.groups');
  }
  for (final group in dns.groups) {
    final path = 'dns.groups.${group.tag}';
    if (group.tag.isEmpty || !tags.add(group.tag)) {
      error('invalid_dns_tag', path);
    }
    if (group.members.length < 2 ||
        group.members.length > 16 ||
        group.members.toSet().length != group.members.length ||
        group.members.any((tag) => !serverTags.contains(tag))) {
      error('invalid_dns_group_members', path);
    }
    final port = ports[group.tag];
    if (port == null || port < 1 || port > 65535 || !occupied.add(port)) {
      error('invalid_dns_group_listener', 'listeners.dnsGroups.${group.tag}');
    }
    graph['dns:${group.tag}'] = [
      for (final member in group.members) 'dns:$member',
    ];
  }
  if (ports.keys.any((tag) => !dns.groups.any((group) => group.tag == tag))) {
    error('unknown_dns_group_listener', 'listeners.dnsGroups');
  }
  if (!tags.contains(dns.finalServer) ||
      dns.proxyServer != null && !tags.contains(dns.proxyServer)) {
    error('unknown_dns_final', 'dns');
  }
  if (dns.cacheCapacity != null &&
      (dns.cacheCapacity! < 1 || dns.cacheCapacity! > 0xffffffff)) {
    error('invalid_dns_cache_capacity', 'dns.cacheCapacity');
  }
  if (dns.fakeIp case final fake?) {
    if (tags.contains(_fakeIpDnsTag)) error('invalid_dns_tag', 'dns.fakeIp');
    if (fake.ipv4Range == null && fake.ipv6Range == null ||
        !_validFakeRange(fake.ipv4Range, 32) ||
        !_validFakeRange(fake.ipv6Range, 128)) {
      error('invalid_fake_ip_range', 'dns.fakeIp');
    }
    if (fake.ttl < 0 || fake.ttl > 0xffffffff) {
      error('invalid_fake_ip_ttl', 'dns.fakeIp.ttl');
    }
    final sets = <CoreRuleSetSpec>[
      for (var i = 0; i < fake.filters.length; i++)
        CoreRuleSetSpec(
          tag: '$i',
          kind: fake.filters[i].set.kind,
          domains: fake.filters[i].set.domains,
          suffixes: fake.filters[i].set.suffixes,
          keywords: fake.filters[i].set.keywords,
          regexes: fake.filters[i].set.regexes,
          prefixes: fake.filters[i].set.prefixes,
        ),
    ];
    if (sets.any((set) => set.kind != CoreRuleSetKind.domain)) {
      error('invalid_dns_filter_kind', 'dns.fakeIp.filters');
    }
    issues.addAll(
      validateCoreRuleSets(sets, path: 'dns.fakeIp.filters', limit: 100000),
    );
  }
  for (final server in dns.servers) {
    if (server.addressResolver != null &&
        !tags.contains(server.addressResolver)) {
      error('unknown_dns_resolver', 'dns.servers.${server.tag}');
    }
  }
  for (final node in profile.nodes) {
    graph['out:${node.tag}'] = [
      if (node.detour != null) 'out:${node.detour}',
      if (node.server != null &&
          InternetAddress.tryParse(node.server!) == null &&
          (node.detour == null || dns.proxyServer != null))
        'dns:${dns.proxyServer ?? dns.finalServer}',
    ];
  }
  for (final group in profile.selectors) {
    graph['out:${group.tag}'] = [
      for (final member in group.members) 'out:$member',
    ];
  }
  final counts = {for (final tag in graph.keys) tag: 0};
  for (final edges in graph.values) {
    for (final edge in edges) {
      if (counts.containsKey(edge)) counts[edge] = counts[edge]! + 1;
    }
  }
  final ready = counts.keys.where((tag) => counts[tag] == 0).toList();
  for (var i = 0; i < ready.length; i++) {
    for (final edge in graph[ready[i]]!) {
      if (!counts.containsKey(edge)) continue;
      counts[edge] = counts[edge]! - 1;
      if (counts[edge] == 0) ready.add(edge);
    }
  }
  if (ready.length != graph.length) error('dns_dependency_cycle', 'dns');
  return issues;
}

String dnsGroupInboundTag(String tag) => 'hotaru-dns-group:$tag';

const _fakeIpDnsTag = 'hotaru-dns-fakeip';

bool _validFakeRange(String? value, int bits) {
  if (value == null) return true;
  final prefix = CoreIpPrefix.parse(value);
  return prefix != null &&
      prefix.network.rawAddress.length * 8 == bits &&
      prefix.prefix <= bits - 2;
}

Map<String, Object?> compileDns(CoreDnsSpec dns, CoreListenerSpec listeners) =>
    {
      'servers': [
        if (dns.fakeIp case final fake?)
          {
            'type': 'fakeip',
            'tag': _fakeIpDnsTag,
            if (fake.ipv4Range != null) 'inet4_range': fake.ipv4Range,
            if (fake.ipv6Range != null) 'inet6_range': fake.ipv6Range,
          },
        for (final server in dns.servers)
          {
            'type': server.protocol.name,
            'tag': server.tag,
            if (server.server != null) 'server': server.server,
            if (server.port != null) 'server_port': server.port,
            if (server.path != null) 'path': server.path,
            if (server.detour != null) 'detour': server.detour,
            if (server.addressResolver != null)
              'domain_resolver': server.addressResolver,
          },
        for (final group in dns.groups)
          {
            'type': 'udp',
            'tag': group.tag,
            'server': '127.0.0.1',
            'server_port': listeners.dnsGroups!.ports[group.tag],
          },
      ],
      if (dns.groups.isNotEmpty || dns.fakeIp != null)
        'rules': [
          if (!dns.ipv6 && dns.fakeIp != null && dns.groups.isNotEmpty)
            {
              'inbound': [
                for (final group in dns.groups) dnsGroupInboundTag(group.tag),
              ],
              'query_type': [28],
              'action': 'predefined',
              'rcode': 0,
            },
          for (final group in dns.groups) ..._groupRules(group),
          if (dns.fakeIp case final fake?) ..._fakeIpRules(fake),
          if (!dns.ipv6 && dns.fakeIp != null)
            {
              'query_type': [28],
              'action': 'predefined',
              'rcode': 0,
            },
        ],
      'final': dns.finalServer,
      // Source fake IPv6 is independent of real-resolution IPv6. Explicit
      // AAAA rules above retain that split without legacy per-action strategy.
      if (!dns.ipv6 && dns.fakeIp == null) 'strategy': 'ipv4_only',
      if (dns.cacheCapacity != null) 'cache_capacity': dns.cacheCapacity,
    };

List<Map<String, Object?>> _fakeIpRules(CoreDnsFakeIpSpec fake) {
  final filters = <Map<String, Object?>>[];
  for (final filter in fake.filters) {
    final rules = compileRuleSet(filter.set)['rules']! as List;
    if (rules.isEmpty && !filter.invert) continue;
    filters.add({
      'type': 'logical',
      'mode': 'and',
      'rules': [
        {
          'domain_regex': ['.'],
        },
        if (rules.isNotEmpty)
          {
            'type': 'logical',
            'mode': 'or',
            'rules': rules,
            if (filter.invert) 'invert': true,
          },
      ],
    });
  }
  if (filters.isEmpty && fake.mode == CoreDnsFilterMode.whitelist) return [];
  return [
    for (final addressQuery in [true, false])
      {
        'type': 'logical',
        'mode': 'and',
        'rules': [
          {
            'query_type': addressQuery ? [1, 28] : [64, 65],
          },
          if (filters.isNotEmpty)
            {
              'type': 'logical',
              'mode': 'or',
              'rules': filters,
              if (fake.mode == CoreDnsFilterMode.blacklist) 'invert': true,
            },
        ],
        'action': addressQuery ? 'route' : 'predefined',
        if (addressQuery) ...{
          'server': _fakeIpDnsTag,
          'rewrite_ttl': fake.ttl,
        } else
          'rcode': 0,
      },
  ];
}

List<Map<String, Object?>> _groupRules(CoreDnsGroupSpec group) {
  final inbound = [dnsGroupInboundTag(group.tag)];
  // Anonymous race rules capture their current evaluation; speculative later
  // evaluations avoid draining earlier races before another upstream starts.
  return [
    for (final member in group.members) ...[
      {
        'inbound': inbound,
        'action': 'evaluate',
        'server': member,
        'speculative': true,
      },
      {
        'type': 'logical',
        'mode': 'and',
        'rules': [
          {'inbound': inbound},
          {'match_response': true},
          {
            'type': 'logical',
            'mode': 'or',
            'invert': true,
            'rules': [
              for (final rcode in [2, 5])
                {'match_response': true, 'response_rcode': rcode},
            ],
          },
        ],
        'action': 'respond',
        'race': true,
      },
    ],
    {'inbound': inbound, 'action': 'reject'},
  ];
}

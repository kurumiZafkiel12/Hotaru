import 'dart:io' show InternetAddress;

import 'dns.dart';
import 'dns_domain_filter.dart';
import 'geodata.dart';
import 'ip_prefix.dart';
import 'profile.dart';

final class CoreDnsImportResult {
  final CoreDnsSpec? dns;
  final List<CoreConfigIssue> issues;

  CoreDnsImportResult(this.dns, List<CoreConfigIssue> issues)
    : issues = List.unmodifiable(issues);
}

CoreDnsImportResult importClashDns(
  Object? value, {
  Map<String, CoreGeoMatchData> geodata = const {},
}) => _ClashDns(geodata).read(value);

final class _ClashDns {
  final Map<String, CoreGeoMatchData> geodata;
  final List<CoreConfigIssue> issues = [];
  final List<CoreDnsServerSpec> servers = [];
  final List<CoreDnsGroupSpec> groups = [];

  _ClashDns(this.geodata);

  void issue(String code, String path, {bool warning = false}) => issues.add(
    CoreConfigIssue(
      code,
      path,
      severity: warning
          ? CoreConfigIssueSeverity.warning
          : CoreConfigIssueSeverity.error,
    ),
  );

  bool flag(Object? value, bool fallback) {
    if (value == null) return fallback;
    if (value is! bool) throw const FormatException();
    return value;
  }

  String pool(Object? value, String tag, String? bootstrap) {
    if (value is! List ||
        value.isEmpty ||
        value.length > 16 ||
        value.any((entry) => entry is! String || entry.isEmpty)) {
      throw const FormatException();
    }
    if (value.length == 1) return add(value.single as String, tag, bootstrap);
    groups.add(
      CoreDnsGroupSpec(
        tag: tag,
        members: [
          for (var i = 0; i < value.length; i++)
            add(value[i] as String, '$tag-$i', bootstrap),
        ],
      ),
    );
    return tag;
  }

  CoreDnsImportResult read(Object? value) {
    try {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        throw const FormatException();
      }
      if (!flag(value['enable'], false)) {
        if (value.length > 1) {
          issue('disabled_dns_settings_not_applied', 'dns', warning: true);
        }
        return CoreDnsImportResult(null, issues);
      }
      for (final key in value.keys) {
        if (const {
          'enable',
          'ipv6',
          'listen',
          'nameserver',
          'default-nameserver',
          'proxy-server-nameserver',
          'enhanced-mode',
          'use-hosts',
          'use-system-hosts',
          'respect-rules',
          'prefer-h3',
          'cache-size',
          'fake-ip-range',
          'fake-ip-range6',
          'fake-ip-filter',
          'fake-ip-filter-mode',
          'fake-ip-ttl',
        }.contains(key)) {
          continue;
        }
        final option = value[key];
        if (const {
              'fallback',
              'fallback-filter',
              'nameserver-policy',
              'proxy-server-nameserver-policy',
            }.contains(key) &&
            (option is List && option.isEmpty ||
                option is Map && option.isEmpty)) {
          continue;
        }
        issue(switch (key) {
          'fallback' || 'fallback-filter' => 'dns_fallback_not_migrated',
          'nameserver-policy' ||
          'proxy-server-nameserver-policy' => 'dns_policy_not_migrated',
          _ => 'unsupported_dns_field',
        }, 'dns.$key');
      }
      if (value.containsKey('listen')) {
        if (value['listen'] is! String) throw const FormatException();
        issue('app_owned_setting_replaced', 'dns.listen', warning: true);
      }
      if (flag(value['respect-rules'], false)) {
        issue('dns_respect_rules_not_migrated', 'dns.respect-rules');
      }
      if (flag(value['prefer-h3'], false)) {
        issue('dns_http3_not_migrated', 'dns.prefer-h3');
      }
      if (flag(value['use-hosts'], true)) {
        issue('dns_hosts_not_migrated', 'dns.use-hosts', warning: true);
      }
      if (flag(value['use-system-hosts'], true)) {
        issue(
          'dns_system_hosts_not_migrated',
          'dns.use-system-hosts',
          warning: true,
        );
      }
      final mode = value['enhanced-mode'];
      if (mode != null &&
          !const ['normal', 'redir-host', 'fake-ip'].contains(mode)) {
        issue('invalid_dns_enhanced_mode', 'dns.enhanced-mode');
      }
      final fakeIp = readFakeIp(value, mode == 'fake-ip');
      String? bootstrap;
      if (value['default-nameserver'] != null) {
        bootstrap = pool(value['default-nameserver'], 'dns-bootstrap', null);
      }
      final main = pool(value['nameserver'], 'dns-main', bootstrap);
      String? proxy;
      if (value['proxy-server-nameserver'] != null) {
        proxy = pool(value['proxy-server-nameserver'], 'dns-proxy', bootstrap);
      }
      final capacity = value['cache-size'];
      if (capacity != null &&
          (capacity is! int || capacity < 1 || capacity > 0xffffffff)) {
        throw const FormatException();
      }
      final spec = CoreDnsSpec(
        servers: servers,
        groups: groups,
        finalServer: main,
        proxyServer: proxy,
        ipv6: flag(value['ipv6'], false),
        cacheCapacity: capacity as int?,
        fakeIp: fakeIp,
      );
      return CoreDnsImportResult(
        issues.any((issue) => issue.severity == CoreConfigIssueSeverity.error)
            ? null
            : spec,
        issues,
      );
    } on FormatException {
      issue('invalid_dns_value', 'dns');
      return CoreDnsImportResult(null, issues);
    }
  }

  CoreDnsFakeIpSpec? readFakeIp(Map<dynamic, dynamic> value, bool active) {
    String? range(String key, String fallback, int bits) {
      final raw = value[key] ?? fallback;
      if (raw == '') return null;
      if (raw is! String) throw const FormatException();
      final prefix = CoreIpPrefix.parse(raw);
      if (prefix == null ||
          prefix.network.rawAddress.length * 8 != bits ||
          prefix.prefix > bits - 2) {
        throw const FormatException();
      }
      return raw;
    }

    final ipv4 = range('fake-ip-range', '198.18.0.1/16', 32);
    final ipv6 = range('fake-ip-range6', '', 128);
    if (!active) {
      if (value.keys.any((key) => key.toString().startsWith('fake-ip-'))) {
        issue('inactive_dns_fake_ip_settings', 'dns', warning: true);
      }
      return null;
    }
    if (ipv4 == null && ipv6 == null) throw const FormatException();
    final mode = value['fake-ip-filter-mode'] ?? 'blacklist';
    if (mode == 'rule') {
      issue('dns_fake_ip_rule_filter_not_migrated', 'dns.fake-ip-filter-mode');
      return null;
    }
    if (mode != 'blacklist' && mode != 'whitelist') {
      throw const FormatException();
    }
    final ttl = value['fake-ip-ttl'] ?? 1;
    if (ttl is! int || ttl < 0 || ttl > 0xffffffff) {
      throw const FormatException();
    }
    final raw =
        value['fake-ip-filter'] ??
        const [
          'dns.msftnsci.com',
          'www.msftnsci.com',
          'www.msftconnecttest.com',
        ];
    if (raw is! List || raw.length > 100000) throw const FormatException();
    final filters = <CoreDnsDomainFilter>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! String) throw const FormatException();
      try {
        filters.addAll(readDnsDomainFilter(entry, geodata));
      } on FormatException catch (error) {
        issue(
          error.message == 'geo_data_required'
              ? 'geo_data_required'
              : 'unsupported_dns_domain_filter',
          'dns.fake-ip-filter.$i',
        );
      }
    }
    return CoreDnsFakeIpSpec(
      ipv4Range: ipv4,
      ipv6Range: ipv6,
      ttl: ttl,
      mode: mode == 'blacklist'
          ? CoreDnsFilterMode.blacklist
          : CoreDnsFilterMode.whitelist,
      filters: filters,
    );
  }

  String add(String address, String tag, String? bootstrap) {
    if (address == 'system' || address == 'system://') {
      servers.add(CoreDnsServerSpec(tag: tag, protocol: CoreDnsProtocol.local));
      return tag;
    }
    final directIp = InternetAddress.tryParse(address);
    final uri = directIp != null
        ? Uri(scheme: 'udp', host: address)
        : Uri.tryParse(address.contains('://') ? address : 'udp://$address');
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.host.contains(RegExp(r'[\s\x00]'))) {
      throw const FormatException();
    }
    final protocol = switch (uri.scheme) {
      'udp' => CoreDnsProtocol.udp,
      'tcp' => CoreDnsProtocol.tcp,
      'tls' => CoreDnsProtocol.tls,
      'https' => CoreDnsProtocol.https,
      _ => null,
    };
    if (protocol == null) throw const FormatException();
    if (uri.hasQuery ||
        protocol != CoreDnsProtocol.https &&
            uri.path.isNotEmpty &&
            uri.path != '/') {
      throw const FormatException();
    }
    final port = uri.hasPort
        ? uri.port
        : switch (protocol) {
            CoreDnsProtocol.tls => 853,
            CoreDnsProtocol.https => 443,
            _ => 53,
          };
    if (port < 1 || port > 65535) throw const FormatException();
    final fragment = uri.fragment;
    if (fragment.contains(RegExp(r'[=&\r\n]'))) throw const FormatException();
    final domain = InternetAddress.tryParse(uri.host) == null;
    if (domain && bootstrap == null) {
      issue(
        'dns_bootstrap_required',
        tag == 'dns-bootstrap' ? 'dns.default-nameserver' : 'dns.nameserver',
      );
    }
    servers.add(
      CoreDnsServerSpec(
        tag: tag,
        protocol: protocol,
        server: uri.host,
        port: port,
        path: protocol == CoreDnsProtocol.https
            ? '${uri.path.isEmpty ? '/dns-query' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}'
            : null,
        detour: fragment.isEmpty || fragment == 'DIRECT' ? null : fragment,
        addressResolver: domain ? bootstrap : null,
      ),
    );
    return tag;
  }
}

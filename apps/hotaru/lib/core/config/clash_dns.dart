import 'dart:io' show InternetAddress;

import 'dns.dart';
import 'profile.dart';

final class CoreDnsImportResult {
  final CoreDnsSpec? dns;
  final List<CoreConfigIssue> issues;

  CoreDnsImportResult(this.dns, List<CoreConfigIssue> issues)
    : issues = List.unmodifiable(issues);
}

CoreDnsImportResult importClashDns(Object? value) => _ClashDns().read(value);

final class _ClashDns {
  final List<CoreConfigIssue> issues = [];
  final List<CoreDnsServerSpec> servers = [];

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

  String single(Object? value, String path) {
    if (value is! List || value.isEmpty) throw const FormatException();
    if (value.length != 1) issue('dns_parallel_servers_not_migrated', path);
    if (value.first is! String || (value.first as String).isEmpty) {
      throw const FormatException();
    }
    return value.first as String;
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
      if (mode != null && mode != 'normal' && mode != 'redir-host') {
        issue('dns_fake_ip_not_migrated', 'dns.enhanced-mode');
      }
      String? bootstrap;
      if (value['default-nameserver'] != null) {
        bootstrap = add(
          single(value['default-nameserver'], 'dns.default-nameserver'),
          'dns-bootstrap',
          null,
        );
      }
      final main = add(
        single(value['nameserver'], 'dns.nameserver'),
        'dns-main',
        bootstrap,
      );
      String? proxy;
      if (value['proxy-server-nameserver'] != null) {
        proxy = add(
          single(
            value['proxy-server-nameserver'],
            'dns.proxy-server-nameserver',
          ),
          'dns-proxy',
          bootstrap,
        );
      }
      final capacity = value['cache-size'];
      if (capacity != null &&
          (capacity is! int || capacity < 1 || capacity > 0xffffffff)) {
        throw const FormatException();
      }
      final spec = CoreDnsSpec(
        servers: servers,
        finalServer: main,
        proxyServer: proxy,
        ipv6: flag(value['ipv6'], false),
        cacheCapacity: capacity as int?,
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

  String add(String address, String tag, String? bootstrap) {
    if (address == 'system') {
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

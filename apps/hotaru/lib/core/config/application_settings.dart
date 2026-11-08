import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../routing_mode.dart';
import 'encoding.dart';
import 'profile.dart';
import 'provider_info.dart';
import 'runtime_options.dart';
import 'yaml_document.dart';

final class CoreApplicationSettings {
  final String source;
  final bool unconfigured;
  final List<CoreProviderInfo> providers;
  final List<CoreConfigIssue> importIssues;
  final String _document;
  final List<CoreConfigIssue> issues;
  final int mixedPort;
  final CoreInboundOptions inbound;
  final CoreRuntimeOptions runtime;
  final CoreTunSpec? tun;
  final CoreRoutingMode mode;
  final int? dnsPort;
  final String? userAgent;
  final Map<String, String> geoUrls;
  final Map<String, String> providerFiles;

  CoreApplicationSettings._({
    required this.source,
    this.unconfigured = false,
    List<CoreProviderInfo> providers = const [],
    List<CoreConfigIssue> importIssues = const [],
    required String document,
    required List<CoreConfigIssue> issues,
    required this.mixedPort,
    required this.inbound,
    required this.runtime,
    required this.tun,
    required this.mode,
    required this.dnsPort,
    required this.userAgent,
    required Map<String, String> geoUrls,
    required Map<String, String> providerFiles,
  }) : importIssues = List.unmodifiable(importIssues),
       providers = List.unmodifiable(providers),
       _document = document,
       issues = List.unmodifiable(issues),
       geoUrls = Map.unmodifiable(geoUrls),
       providerFiles = Map.unmodifiable(providerFiles);

  static Future<CoreApplicationSettingsResult> parse(
    String source, {
    required bool skipCertVerify,
    Map<String, String> authorizedProviderFiles = const {},
    bool unconfigured = false,
  }) {
    final files = Map<String, String>.of(authorizedProviderFiles);
    return Isolate.run(
      () => _SettingsReader().read(
        source,
        skipCertVerify,
        files,
        unconfigured: unconfigured,
      ),
    );
  }

  CoreApplicationSettings withProviders(
    List<CoreProviderInfo> providers, {
    List<CoreConfigIssue>? importIssues,
  }) => CoreApplicationSettings._(
    source: source,
    unconfigured: unconfigured,
    document: _document,
    issues: issues,
    providers: providers,
    importIssues: importIssues ?? this.importIssues,
    mixedPort: mixedPort,
    inbound: inbound,
    runtime: runtime,
    tun: tun,
    mode: mode,
    dnsPort: dnsPort,
    userAgent: userAgent,
    geoUrls: geoUrls,
    providerFiles: providerFiles,
  );

  Future<CoreApplicationSettingsResult> updated(
    Map<String, Object?> values, {
    required bool skipCertVerify,
  }) {
    final patch = Map<String, Object?>.of(values);
    final source = _document;
    final files = providerFiles;
    final retainedProviders = providers;
    final retainedIssues = importIssues;
    final initial = unconfigured;
    return Isolate.run(() {
      const allowed = {
        'tun',
        'mixed-port',
        'allow-lan',
        'find-process-mode',
        'mode',
        'log-level',
        'ipv6',
        'tcp-concurrent',
        'unified-delay',
        'authentication',
        'geo-auto-update',
        'geo-update-interval',
        'geox-url',
      };
      final document = decodeCoreYaml(source) as Map<String, dynamic>;
      for (final entry in patch.entries) {
        if (allowed.contains(entry.key) && entry.value != null) {
          if (entry.key == 'tun' && entry.value is Map) {
            document[entry.key] = {
              if (document[entry.key] case final Map old) ...old,
              ...entry.value as Map,
            };
          } else {
            document[entry.key] = entry.value;
          }
        }
      }
      final projected = _SettingsReader().read(
        utf8.decode(CoreConfigEncoding.encode(document)),
        skipCertVerify,
        files,
        unconfigured: initial,
      );
      return CoreApplicationSettingsResult(
        projected.settings?.withProviders(
          retainedProviders,
          importIssues: retainedIssues,
        ),
        projected.issues,
      );
    });
  }
}

final class CoreApplicationSettingsResult {
  final CoreApplicationSettings? settings;
  final List<CoreConfigIssue> issues;

  CoreApplicationSettingsResult(this.settings, List<CoreConfigIssue> issues)
    : issues = List.unmodifiable(issues);
}

final class _SettingsReader {
  final issues = <CoreConfigIssue>[];
  String _path = 'document';

  void issue(String code, String path, {bool warning = false}) => issues.add(
    CoreConfigIssue(
      code,
      path,
      severity: warning
          ? CoreConfigIssueSeverity.warning
          : CoreConfigIssueSeverity.error,
    ),
  );

  T field<T>(String path, T Function() read) {
    _path = path;
    return read();
  }

  bool flag(Object? value, bool fallback) {
    if (value == null) return fallback;
    if (value is! bool) throw const FormatException();
    return value;
  }

  String text(Object? value, [String fallback = '']) {
    if (value == null) return fallback;
    if (value is! String || value.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException();
    }
    return value;
  }

  int integer(Object? value, int fallback, {int min = 0, int max = 65535}) {
    final number = value ?? fallback;
    if (number is! int || number < min || number > max) {
      throw const FormatException();
    }
    return number;
  }

  Map<String, dynamic> mapping(Object? value) {
    if (value == null) return {};
    if (value is! Map<String, dynamic>) throw const FormatException();
    return Map.of(value);
  }

  List<String> strings(Object? value, {int limit = 4096}) {
    if (value == null) return [];
    if (value is! List ||
        value.length > limit ||
        value.any((v) => v is! String)) {
      throw const FormatException();
    }
    return value.cast<String>();
  }

  CoreApplicationSettingsResult read(
    String source,
    bool skipCertVerify,
    Map<String, String> files, {
    bool unconfigured = false,
  }) {
    try {
      final document = mapping(decodeCoreYaml(source));
      normalizeProviderPaths(document, files);
      final mixedPort = field(
        'mixed-port',
        () => integer(document.remove('mixed-port'), 7890, min: 1),
      );
      final allowLan = field(
        'allow-lan',
        () => flag(document.remove('allow-lan'), false),
      );
      final bind = field(
        'bind-address',
        () => text(document.remove('bind-address'), '*'),
      );
      final listen = !allowLan
          ? '127.0.0.1'
          : bind == '*'
          ? '0.0.0.0'
          : bind;
      if (InternetAddress.tryParse(listen) == null || listen.contains('%')) {
        issue('invalid_inbound_address', 'bind-address');
      }
      final http = field('port', () => integer(document.remove('port'), 0));
      final socks = field(
        'socks-port',
        () => integer(document.remove('socks-port'), 0),
      );
      final credentials = field(
        'authentication',
        () => strings(document.remove('authentication'), limit: 128),
      );
      final users = <CoreLocalCredential>[];
      for (var i = 0; i < credentials.length; i++) {
        final entry = credentials[i];
        final colon = entry.indexOf(':');
        if (colon <= 0) {
          issue('invalid_inbound_user', 'authentication.$i');
        } else {
          users.add(
            CoreLocalCredential(
              entry.substring(0, colon),
              entry.substring(colon + 1),
            ),
          );
        }
      }
      final exemptions = field(
        'skip-auth-prefixes',
        () => strings(document.remove('skip-auth-prefixes')),
      );
      if (exemptions.isNotEmpty) {
        issue('authentication_exemptions_not_migrated', 'skip-auth-prefixes');
      }
      final process = field(
        'find-process-mode',
        () => text(document.remove('find-process-mode'), 'off'),
      );
      if (!const {'off', 'strict', 'always'}.contains(process)) {
        issue('invalid_process_mode', 'find-process-mode');
      }
      final ipv6 = field('ipv6', () => flag(document.remove('ipv6'), false));
      final logLevel = field(
        'log-level',
        () => text(document.remove('log-level'), 'info'),
      );
      final interface = field(
        'interface-name',
        () => text(document.remove('interface-name')),
      );
      final idle = field(
        'keep-alive-idle',
        () =>
            integer(document.remove('keep-alive-idle'), 15, min: 1, max: 86400),
      );
      final interval = field(
        'keep-alive-interval',
        () => integer(
          document.remove('keep-alive-interval'),
          30,
          min: 1,
          max: 86400,
        ),
      );
      final disableKeepAlive = field(
        'disable-keep-alive',
        () => flag(document.remove('disable-keep-alive'), false),
      );
      final runtime = CoreRuntimeOptions(
        logLevel: logLevel,
        findProcess: process != 'off',
        defaultInterface: interface.isEmpty ? null : interface,
        resolveIpv6: ipv6,
        tcpKeepAliveSeconds: idle,
        tcpKeepAliveIntervalSeconds: interval,
        disableTcpKeepAlive: disableKeepAlive,
        skipCertVerify: skipCertVerify,
      );
      final modeName = field(
        'mode',
        () => text(document.remove('mode'), 'rule'),
      );
      final mode = CoreRoutingMode.values
          .where((mode) => mode.name == modeName)
          .firstOrNull;
      if (mode == null) issue('unsupported_routing_mode', 'mode');
      for (final key in ['tcp-concurrent', 'unified-delay']) {
        if (document.containsKey(key)) {
          field(key, () => flag(document.remove(key), true));
          issue('native_dial_semantics_changed', key, warning: true);
        }
      }
      for (final key in ['redir-port', 'tproxy-port', 'routing-mark']) {
        if (field(
              key,
              () => integer(document.remove(key), 0, max: 0xffffffff),
            ) !=
            0) {
          issue('unsupported_windows_network_setting', key);
        }
      }
      for (final key in [
        'external-controller',
        'external-controller-tls',
        'external-controller-unix',
        'external-controller-pipe',
        'external-ui',
        'external-ui-url',
      ]) {
        if (field(key, () => text(document.remove(key))).isNotEmpty) {
          issue('app_owned_setting_replaced', key, warning: true);
        }
      }
      field('secret', () => text(document.remove('secret')));
      final userAgent = field(
        'global-ua',
        () => text(document.remove('global-ua')),
      );
      final geoUrls = field(
        'geox-url',
        () => mapping(document.remove('geox-url')),
      );
      final urls = <String, String>{};
      for (final entry in geoUrls.entries) {
        if (!const {'geoip', 'geosite', 'mmdb', 'asn'}.contains(entry.key)) {
          issue('unsupported_geo_resource', 'geox-url.${entry.key}');
        }
        final value = field('geox-url.${entry.key}', () => text(entry.value));
        final uri = Uri.tryParse(value);
        if (uri == null ||
            !const {'http', 'https'}.contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment) {
          issue('invalid_geo_url', 'geox-url.${entry.key}');
        } else {
          urls[entry.key] = value;
        }
      }
      if (field(
        'geo-auto-update',
        () => flag(document.remove('geo-auto-update'), false),
      )) {
        issue('geo_scheduler_required', 'geo-auto-update');
      }
      field(
        'geo-update-interval',
        () => integer(
          document.remove('geo-update-interval'),
          24,
          min: 1,
          max: 8760,
        ),
      );
      final hosts = field('hosts', () => mapping(document.remove('hosts')));
      if (hosts.isNotEmpty) issue('hosts_not_migrated', 'hosts');
      final profile = field(
        'profile',
        () => mapping(document.remove('profile')),
      );
      for (final entry in profile.entries) {
        if (entry.key == 'store-selected') {
          if (field('profile.store-selected', () => flag(entry.value, false))) {
            issue(
              'app_owned_setting_replaced',
              'profile.store-selected',
              warning: true,
            );
          }
        } else if (entry.key == 'store-fake-ip' && entry.value == false) {
          continue;
        } else {
          issue('unsupported_profile_setting', 'profile.${entry.key}');
        }
      }
      for (final key in ['sniffer', 'ntp', 'tuic-server', 'iptables']) {
        final value = field(key, () => mapping(document.remove(key)));
        if (field('$key.enable', () => flag(value['enable'], false))) {
          issue('unsupported_application_feature', key);
        } else if (value.keys.any((entry) => entry != 'enable')) {
          issue('inactive_settings_not_applied', key, warning: true);
        }
      }
      for (final key in ['listeners', 'tunnels']) {
        final value = document.remove(key);
        if (value != null && (value is! List || value.isNotEmpty)) {
          issue('unsupported_application_feature', key);
        }
      }
      for (final key in ['ss-config', 'vmess-config']) {
        if (field(key, () => text(document.remove(key))).isNotEmpty) {
          issue('unsupported_application_feature', key);
        }
      }
      final tun = readTun(
        field('tun', () => mapping(document.remove('tun'))),
        ipv6,
      );
      int? dnsPort;
      if (document['dns'] case final Map<String, dynamic> value) {
        final dns = Map<String, dynamic>.of(value);
        final address = field('dns.listen', () => text(dns.remove('listen')));
        if (address.isNotEmpty && dns['enable'] == true) {
          final uri = Uri.tryParse('udp://$address');
          if (uri == null ||
              uri.userInfo.isNotEmpty ||
              uri.hasQuery ||
              uri.hasFragment ||
              uri.path.isNotEmpty ||
              !uri.hasPort ||
              !const {'127.0.0.1', '::1', '0.0.0.0', '::'}.contains(uri.host) ||
              uri.port < 1 ||
              uri.port > 65535) {
            issue('unsupported_dns_listener', 'dns.listen');
          } else {
            dnsPort = uri.port;
            if (uri.host != '127.0.0.1') {
              issue('app_owned_setting_replaced', 'dns.listen', warning: true);
            }
          }
        }
        if (dns['enable'] == true && !dns.containsKey('default-nameserver')) {
          dns['default-nameserver'] = [
            '114.114.114.114',
            '223.5.5.5',
            '8.8.8.8',
            '1.0.0.1',
          ];
        }
        document['dns'] = dns;
      }
      if (issues.any(
        (issue) => issue.severity == CoreConfigIssueSeverity.error,
      )) {
        return CoreApplicationSettingsResult(null, issues);
      }
      return CoreApplicationSettingsResult(
        CoreApplicationSettings._(
          source: utf8.decode(CoreConfigEncoding.encode(document)),
          document: source,
          unconfigured: unconfigured,
          issues: issues,
          mixedPort: mixedPort,
          inbound: CoreInboundOptions(
            listen: listen,
            users: users,
            httpPort: http == 0 ? null : http,
            socksPort: socks == 0 ? null : socks,
          ),
          runtime: runtime,
          tun: tun,
          mode: mode!,
          dnsPort: dnsPort,
          userAgent: userAgent.isEmpty ? null : userAgent,
          geoUrls: urls,
          providerFiles: files,
        ),
        issues,
      );
    } on CoreConfigSizeException {
      return CoreApplicationSettingsResult(null, [
        const CoreConfigIssue('configuration_too_large', 'document'),
      ]);
    } on Exception {
      return CoreApplicationSettingsResult(null, [
        CoreConfigIssue('invalid_application_setting', _path),
      ]);
    }
  }

  void normalizeProviderPaths(
    Map<String, dynamic> document,
    Map<String, String> files,
  ) {
    if (files.length > 4096) {
      throw const FormatException('provider_file_grant_limit');
    }
    final aliases = <String, String>{};
    for (final entry in files.entries) {
      if (!RegExp(r'^hotaru-files/[a-z0-9_-]{1,128}$').hasMatch(entry.key) ||
          !p.isAbsolute(entry.value) ||
          aliases.containsKey(p.normalize(entry.value))) {
        throw const FormatException('invalid_provider_file_grant');
      }
      aliases[p.normalize(entry.value)] = entry.key;
    }
    for (final section in ['proxy-providers', 'rule-providers']) {
      final raw = document[section];
      if (raw is! Map<String, dynamic>) continue;
      final providers = Map<String, dynamic>.of(raw);
      for (final entry in providers.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        final provider = Map<String, dynamic>.of(
          entry.value as Map<String, dynamic>,
        );
        if (provider['type'] == 'http' && provider.containsKey('path')) {
          if (provider['path'] is! String) throw const FormatException();
          provider.remove('path');
          issue(
            'provider_cache_path_client_owned',
            '$section.${entry.key}.path',
            warning: true,
          );
        } else if (provider['type'] == 'file' && provider['path'] is String) {
          final reference = aliases[p.normalize(provider['path'] as String)];
          if (reference != null) provider['path'] = reference;
        }
        providers[entry.key] = provider;
      }
      document[section] = providers;
    }
  }

  CoreTunSpec? readTun(Map<String, dynamic> value, bool ipv6) {
    if (!field('tun.enable', () => flag(value['enable'], false))) return null;
    for (final key in value.keys) {
      if (!const {
        'enable',
        'device',
        'stack',
        'auto-route',
        'auto-detect-interface',
        'dns-hijack',
        'mtu',
        'route-address',
        'route-exclude-address',
      }.contains(key)) {
        issue('unsupported_tun_setting', 'tun.$key');
      }
    }
    final stack = field('tun.stack', () => text(value['stack'], 'system'));
    if (!const {'system', 'gvisor', 'mixed', 'mips'}.contains(stack)) {
      issue('invalid_tun_stack', 'tun.stack');
    } else if (stack != 'system') {
      issue('native_tun_stack_changed', 'tun.stack', warning: true);
    }
    final automatic = field(
      'tun.auto-detect-interface',
      () => flag(value['auto-detect-interface'], true),
    );
    if (!automatic) {
      issue('interface_detection_required', 'tun.auto-detect-interface');
    }
    final hijack = field('tun.dns-hijack', () => strings(value['dns-hijack']));
    if (hijack.isNotEmpty &&
        (hijack.length != 1 || hijack.single != 'any:53')) {
      issue('unsupported_dns_hijack', 'tun.dns-hijack');
    }
    return CoreTunSpec(
      interfaceName: field('tun.device', () => text(value['device'], 'Hotaru')),
      addresses: ['172.19.0.1/30', if (ipv6) 'fdfe:dcba:9876::1/126'],
      autoRoute: field('tun.auto-route', () => flag(value['auto-route'], true)),
      hijackDns: hijack.isNotEmpty,
      mtu: field('tun.mtu', () => integer(value['mtu'], 9000, min: 1280)),
      routes: field('tun.route-address', () => strings(value['route-address'])),
      excludedRoutes: field(
        'tun.route-exclude-address',
        () => strings(value['route-exclude-address']),
      ),
    );
  }
}

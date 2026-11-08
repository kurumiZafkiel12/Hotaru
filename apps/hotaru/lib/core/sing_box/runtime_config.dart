import 'dart:io';

import '../config/ip_prefix.dart';
import '../config/profile.dart';
import '../config/runtime_options.dart';

List<CoreConfigIssue> validateRuntimeOptions(
  CoreProfileSpec profile,
  CoreListenerSpec listeners,
) {
  final issues = <CoreConfigIssue>[];
  void error(String code, String path) =>
      issues.add(CoreConfigIssue(code, path));
  final runtime = profile.runtime;
  if (!runtime.resolveIpv6 && profile.dns == null) {
    error('dns_required_for_ip_family_policy', 'runtime.resolveIpv6');
  }
  if ([
    runtime.tcpKeepAliveSeconds,
    runtime.tcpKeepAliveIntervalSeconds,
  ].any((seconds) => seconds != null && (seconds < 1 || seconds > 86400))) {
    error('invalid_tcp_keep_alive', 'runtime');
  }
  if (runtime.logLevel != null &&
      !const [
        'trace',
        'debug',
        'info',
        'warning',
        'error',
        'silent',
      ].contains(runtime.logLevel)) {
    error('invalid_log_level', 'runtime.logLevel');
  }
  if (runtime.defaultInterface case final name?) {
    if (name.isEmpty ||
        name.length > 256 ||
        name.contains(RegExp(r'[\x00-\x1f]'))) {
      error('invalid_default_interface', 'runtime.defaultInterface');
    }
  }
  final occupied = <int>{listeners.controllerPort, listeners.mixedPort};
  final inbound = listeners.inbound;
  if (inbound != null) {
    if (InternetAddress.tryParse(inbound.listen) == null ||
        inbound.listen.contains('%')) {
      error('invalid_inbound_address', 'listeners.inbound.listen');
    }
    for (final entry in {
      'httpPort': inbound.httpPort,
      'socksPort': inbound.socksPort,
    }.entries) {
      if (entry.value case final port?) {
        if (port < 1 ||
            port > 65535 ||
            !occupied.add(port) ||
            port == listeners.dnsPort ||
            port == listeners.probe?.port) {
          error('invalid_inbound_port', 'listeners.inbound.${entry.key}');
        }
      }
    }
    final names = <String>{};
    if (inbound.users.length > 128) {
      error('inbound_user_limit', 'listeners.inbound.users');
    }
    for (var i = 0; i < inbound.users.length; i++) {
      final user = inbound.users[i];
      if (!_validCredential(user) || !names.add(user.username)) {
        error('invalid_inbound_user', 'listeners.inbound.users.$i');
      }
    }
  }
  final tun = listeners.tun;
  if (tun != null) {
    if (tun.mtu != null && (tun.mtu! < 1280 || tun.mtu! > 65535)) {
      error('invalid_tun_mtu', 'listeners.tun.mtu');
    }
    for (final entry in {
      'routes': tun.routes,
      'excludedRoutes': tun.excludedRoutes,
    }.entries) {
      if (entry.value.length > 4096 ||
          entry.value.any((route) => CoreIpPrefix.parse(route) == null)) {
        error('invalid_tun_routes', 'listeners.tun.${entry.key}');
      }
    }
  }
  return issues;
}

bool _validCredential(CoreLocalCredential user) =>
    user.username.isNotEmpty &&
    user.username.length <= 256 &&
    user.password.length <= 4096 &&
    !user.username.contains(RegExp(r'[\x00-\x1f:]')) &&
    !user.password.contains(RegExp(r'[\x00-\x1f]'));

List<Map<String, Object?>> compileDataInbounds(CoreListenerSpec listeners) {
  if (!listeners.inboundsEnabled) return [];
  final options = listeners.inbound;
  return [
    for (final entry in <String, int?>{
      'mixed': listeners.mixedPort,
      'http': options?.httpPort,
      'socks': options?.socksPort,
    }.entries)
      if (entry.value != null)
        {
          'type': entry.key,
          'tag': entry.key,
          'listen': options?.listen ?? '127.0.0.1',
          'listen_port': entry.value,
          if (options?.users.isNotEmpty == true)
            'users': [
              for (final user in options!.users)
                {'username': user.username, 'password': user.password},
            ],
        },
  ];
}

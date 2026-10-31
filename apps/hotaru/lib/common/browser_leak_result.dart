import 'dart:convert';
import 'dart:io';

import 'dns_leak.dart';
import 'country_names.dart';
import 'network_diagnostics.dart';

enum BrowserLeakKind { dns, webrtc }

class BrowserLeakResult {
  const BrowserLeakResult({
    required this.kind,
    required this.completed,
    this.resolvers = const [],
    this.remote = const [],
    this.public = const [],
    this.local = const [],
    this.supported = false,
  });

  final BrowserLeakKind kind;
  final bool completed;
  final List<DnsResolverReceipt> resolvers;
  final List<String> remote;
  final List<String> public;
  final List<String> local;
  final bool supported;

  factory BrowserLeakResult.fromSnapshot(BrowserLeakKind kind, Object? value) {
    if (value is String) value = jsonDecode(value);
    if (value is! Map || value['origin'] != 'https://browserleaks.com') {
      throw const FormatException('unexpected diagnostic origin');
    }
    final fields = value['fields'] is Map ? value['fields'] as Map : const {};
    List<String> addresses(Object? value, {bool publicOnly = false}) {
      if (value is! String) return const [];
      return {
        for (final part in value.split(RegExp(r'[\s,;]+')))
          if (InternetAddress.tryParse(part) case final InternetAddress address)
            if (!publicOnly || isPublicProbeAddress(address)) address.address,
      }.toList();
    }

    final resolvers = <String, DnsResolverReceipt>{};
    if (value['resolvers'] case final List rows) {
      for (final row in rows) {
        if (row is! Map) continue;
        for (final ip in addresses(row['ip'], publicOnly: true)) {
          resolvers[ip] = DnsResolverReceipt(
            ip: ip,
            organization: row['organization'] is String
                ? (row['organization'] as String).trim()
                : '',
            country: row['country'] is String
                ? _countryCodes[(row['country'] as String)
                          .split(',')
                          .first
                          .trim()] ??
                      ''
                : '',
          );
        }
      }
    }
    final remote = [
      ...addresses(fields['client-ipv4'], publicOnly: true),
      ...addresses(fields['client-ipv6'], publicOnly: true),
    ];
    final public = addresses(fields['rtc-public'], publicOnly: true);
    final supported = '${fields['rtc-peerconnection']}'.toLowerCase().contains(
      'true',
    );
    return BrowserLeakResult(
      kind: kind,
      completed: value['completed'] == true,
      supported: supported,
      remote: remote,
      public: public,
      local: addresses(fields['rtc-local']),
      resolvers: resolvers.values.toList(),
    );
  }

  bool get hasDnsRisk => resolvers.any((resolver) => resolver.domesticIsp);

  bool get hasRtcMismatch =>
      completed &&
      supported &&
      remote.isNotEmpty &&
      public.any(
        (address) =>
            remote.any(
              (baseline) =>
                  InternetAddress(baseline).type ==
                  InternetAddress(address).type,
            ) &&
            !remote.contains(address),
      );

  bool get rtcMatches =>
      completed &&
      supported &&
      public.isNotEmpty &&
      remote.isNotEmpty &&
      public.every(remote.contains);
}

final _countryCodes = {
  for (var a = 65; a <= 90; a++)
    for (var b = 65; b <= 90; b++)
      if (countryName(String.fromCharCodes([a, b]), 'en')
          case final String name)
        name: String.fromCharCodes([a, b]),
};

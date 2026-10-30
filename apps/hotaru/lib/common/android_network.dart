import 'dart:io';

enum AndroidNetworkSetting {
  vpn('vpn'),
  privateDns('private-dns'),
  wifi('wifi'),
  application('application');

  const AndroidNetworkSetting(this.platformValue);
  final String platformValue;
}

class AndroidNetworkSnapshot {
  const AndroidNetworkSnapshot({
    required this.readable,
    this.api = 0,
    this.active,
    this.vpn,
    this.validated,
    this.captivePortal,
    this.metered,
    this.privateDnsActive,
    this.privateDnsName = '',
    this.transports = const [],
    this.dnsServers = const [],
    this.mtu,
    this.reason = '',
  });

  final bool readable;
  final int api;
  final bool? active;
  final bool? vpn;
  final bool? validated;
  final bool? captivePortal;
  final bool? metered;
  final bool? privateDnsActive;
  final String privateDnsName;
  final List<String> transports;
  final List<String> dnsServers;
  final int? mtu;
  final String reason;

  factory AndroidNetworkSnapshot.fromJson(Map<String, Object?>? json) {
    final rawApi = json?['api'];
    final api = rawApi is int && rawApi > 0 ? rawApi : 0;
    if (json == null || json['readable'] != true) {
      return AndroidNetworkSnapshot(
        readable: false,
        api: api,
        reason: json?['reason'] == 'permission' ? 'permission' : 'unavailable',
      );
    }
    bool? flag(String key) => json[key] is bool ? json[key] as bool : null;
    final mtu = json['mtu'] is int ? json['mtu'] as int : null;
    final rawTransports = json['transports'];
    final rawDns = json['dns-servers'];
    final name = json['private-dns-name'];
    return AndroidNetworkSnapshot(
      readable: true,
      api: api,
      active: flag('active'),
      vpn: flag('vpn'),
      validated: flag('validated'),
      captivePortal: flag('captive-portal'),
      metered: flag('metered'),
      privateDnsActive: api >= 28 ? flag('private-dns-active') : null,
      privateDnsName:
          api >= 28 &&
              name is String &&
              name.length <= 253 &&
              !RegExp(r'[\s\x00-\x1f]').hasMatch(name)
          ? name
          : '',
      transports: List.unmodifiable(
        rawTransports is List
            ? rawTransports
                  .whereType<String>()
                  .where(
                    const {
                      'wifi',
                      'cellular',
                      'ethernet',
                      'vpn',
                      'bluetooth',
                    }.contains,
                  )
                  .toSet()
            : <String>[],
      ),
      dnsServers: List.unmodifiable(
        rawDns is List
            ? rawDns.whereType<String>().where((value) {
                final parts = value.split('%');
                return parts.length <= 2 &&
                    InternetAddress.tryParse(parts.first) != null &&
                    (parts.length == 1 ||
                        RegExp(r'^[A-Za-z0-9_.-]{1,32}$').hasMatch(parts.last));
              }).toSet()
            : <String>[],
      ),
      mtu: mtu != null && mtu > 0 && mtu <= 65535 ? mtu : null,
    );
  }
}

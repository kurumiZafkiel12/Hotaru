import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/android_network.dart';

void main() {
  test(
    'unavailable or absent fields stay unknown instead of reporting VPN or DNS as disabled',
    () {
      for (final data in <Map<String, Object?>?>[
        null,
        {},
        {'readable': false, 'api': 35, 'vpn': true, 'reason': 'permission'},
      ]) {
        final snapshot = AndroidNetworkSnapshot.fromJson(data);
        expect(snapshot.readable, isFalse);
        expect(snapshot.vpn, isNull);
        expect(snapshot.privateDnsActive, isNull);
      }
      final snapshot = AndroidNetworkSnapshot.fromJson({
        'readable': true,
        'api': 35,
        'vpn': false,
        'validated': 'true',
      });
      expect(snapshot.vpn, isFalse);
      expect(snapshot.validated, isNull);
      expect(snapshot.privateDnsActive, isNull);
    },
  );

  test(
    'system DNS accepts actual local gateways and IPv6 without classifying them as leaks',
    () {
      final snapshot = AndroidNetworkSnapshot.fromJson({
        'readable': true,
        'api': 35,
        'dns-servers': [
          '192.168.1.1',
          '2606:4700:4700::1111',
          'fe80::1%wlan0',
          '192.168.1.1',
          'not-an-ip',
          123,
        ],
        'transports': ['vpn', 'wifi', 'wifi', 'unknown'],
        'private-dns-active': true,
        'private-dns-name': 'dns.google',
        'mtu': 1500,
      });
      expect(snapshot.dnsServers, [
        '192.168.1.1',
        '2606:4700:4700::1111',
        'fe80::1%wlan0',
      ]);
      expect(snapshot.transports, ['vpn', 'wifi']);
      expect(snapshot.privateDnsActive, isTrue);
      expect(snapshot.privateDnsName, 'dns.google');
      expect(snapshot.mtu, 1500);
      expect(() => snapshot.dnsServers.add('1.1.1.1'), throwsUnsupportedError);
    },
  );

  test(
    'pre-Android-9 snapshots never pretend to expose the Private DNS API',
    () {
      final snapshot = AndroidNetworkSnapshot.fromJson({
        'readable': true,
        'api': 24,
        'private-dns-active': true,
        'private-dns-name': 'dns.google',
        'mtu': -1,
      });
      expect(snapshot.privateDnsActive, isNull);
      expect(snapshot.privateDnsName, isEmpty);
      expect(snapshot.mtu, isNull);
    },
  );
}

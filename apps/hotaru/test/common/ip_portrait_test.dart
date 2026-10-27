import 'dart:convert';

import 'package:hotaru/common/ip_portrait.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('geolocation parsers read their own source shapes', () {
    test('ip-api', () {
      final result = parseIpApiGeo(
        jsonEncode({
          'status': 'success',
          'countryCode': 'US',
          'city': 'Ashburn',
        }),
      );
      expect(result.countryCode, 'US');
      expect(result.city, 'Ashburn');
      expect(parseIpApiGeo(jsonEncode({'status': 'fail'})).answered, isFalse);
    });

    test('ipwho.is', () {
      final result = parseIpWhoGeo(
        jsonEncode({'country_code': 'JP', 'city': 'Tokyo'}),
      );
      expect(result.countryCode, 'JP');
      expect(result.city, 'Tokyo');
      expect(parseIpWhoGeo(jsonEncode({'success': false})).answered, isFalse);
    });

    test('db-ip', () {
      final result = parseDbIpGeo(
        jsonEncode({'countryCode': 'DE', 'city': 'Frankfurt'}),
      );
      expect(result.countryCode, 'DE');
      expect(result.city, 'Frankfurt');
    });

    test('ipinfo', () {
      final result = parseIpInfoGeo(
        jsonEncode({'country': 'US', 'city': 'Mountain View'}),
      );
      expect(result.countryCode, 'US');
      expect(parseIpInfoGeo(jsonEncode({'bogon': true})).answered, isFalse);
    });

    test('ip.sb', () {
      final result = parseIpSbGeo(
        jsonEncode({'country_code': 'US', 'city': 'Mountain View'}),
      );
      expect(result.countryCode, 'US');
      expect(result.city, 'Mountain View');
    });

    test('garbage answers nothing instead of throwing', () {
      for (final parse in [
        parseIpApiGeo,
        parseIpWhoGeo,
        parseDbIpGeo,
        parseIpInfoGeo,
        parseIpSbGeo,
      ]) {
        expect(parse('not json').answered, isFalse);
        expect(parse(null).answered, isFalse);
      }
    });
  });

  test('proxycheck details carry the risk score, range and hostname', () {
    final details = parseProxyCheckDetails(
      jsonEncode({
        'status': 'ok',
        '8.8.8.8': {
          'network': {'range': '8.8.8.0/24', 'hostname': 'dns.google'},
          'detections': {'risk': 100, 'proxy': false},
        },
      }),
      '8.8.8.8',
    );
    expect(details.risk, 100);
    expect(details.range, '8.8.8.0/24');
    expect(details.hostname, 'dns.google');
    expect(parseProxyCheckDetails('{}', '8.8.8.8').risk, isNull);
  });
}

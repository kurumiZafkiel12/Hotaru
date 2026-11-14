import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hotaru/common/ip_facts.dart';
import 'package:hotaru/models/ip_facts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const enabled = bool.fromEnvironment('IP_SOURCE_CONTRACT_LIVE');
  for (final ip in ['8.8.8.8', '2001:4860:4860::8888']) {
    test(
      'production parser observes public provider sample $ip',
      () async {
        final dio = Dio();
        addTearDown(() => dio.close(force: true));
        final facts = await lookupIpFacts(dio, ip, cancelToken: CancelToken());
        stdout.writeln(
          jsonEncode({
            'scope':
                'Provider schema only; CI network, not Hotaru routing or release acceptance',
            'ip': facts.ip,
            'geo_country': facts.geoCountry,
            'block_country': facts.registeredCountry,
            'origin': facts.origin.name,
            'attribute': facts.attribute.name,
            'score_source': 'Scamalytics',
            'score': facts.riskScore,
            'risk': facts.risk.name,
            'statuses': [
              facts.locationStatus.name,
              facts.registryStatus.name,
              facts.scoreStatus.name,
            ],
          }),
        );
        expect(facts.locationStatus, IpFactStatus.available);
        expect(facts.geoCountry, 'US');
        expect(facts.attribute, IpAttribute.hosting);
        expect(facts.scoreStatus, IpFactStatus.available);
        expect(facts.riskScore, inInclusiveRange(0, 100));
        if (facts.registeredCountry == null) {
          expect(facts.origin, IpOrigin.unknown);
        }
        if (facts.registeredCountry == 'US') {
          expect(facts.origin, IpOrigin.native);
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(seconds: 40)),
    );
  }
}

import 'dart:convert';

import 'package:hotaru/models/ip_facts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime.utc(2026, 11, 6);
  final facts = IpFacts(
    ip: '8.8.8.8',
    checkedAt: at,
    locationCheckedAt: at,
    registryCheckedAt: at,
    scoreCheckedAt: at,
    geoCountry: 'US',
    registeredCountry: 'US',
    attribute: IpAttribute.hosting,
    riskScore: 3,
    locationStatus: IpFactStatus.available,
    registryStatus: IpFactStatus.available,
    scoreStatus: IpFactStatus.available,
  );

  for (final (score, risk) in [
    (-1, IpRisk.unknown),
    (0, IpRisk.low),
    (19, IpRisk.low),
    (20, IpRisk.medium),
    (59, IpRisk.medium),
    (60, IpRisk.elevated),
    (89, IpRisk.elevated),
    (90, IpRisk.high),
    (100, IpRisk.high),
    (101, IpRisk.unknown),
  ]) {
    test(
      'Scamalytics boundary $score is $risk',
      () => expect(facts.copyWith(riskScore: score).risk, risk),
    );
  }
  test('hosting is never used to infer risk', () {
    expect(facts.copyWith(riskScore: null).risk, IpRisk.unknown);
    expect(
      facts.copyWith(scoreStatus: IpFactStatus.unavailable).risk,
      IpRisk.unknown,
    );
  });
  test('persistent record round trips without losing source timestamps', () {
    final copy = IpFacts.fromJson(
      Map<String, Object?>.from(jsonDecode(jsonEncode(facts.toJson()))),
    );
    expect(copy, facts);
    expect(copy.origin, IpOrigin.native);
    expect(copy.expiresAt, at.add(const Duration(days: 1)));
  });
  test('only missing source gets a short retry deadline', () {
    expect(
      facts.copyWith(registryStatus: IpFactStatus.noData).expiresAt,
      at.add(const Duration(minutes: 5)),
    );
  });
}

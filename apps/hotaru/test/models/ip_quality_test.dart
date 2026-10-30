import 'dart:convert';

import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

IpQuality _quality(
  IpType type, {
  bool isProxy = false,
  bool isVpn = false,
  bool isTor = false,
  bool isAbuser = false,
}) {
  return IpQuality(
    ip: '203.0.113.9',
    source: IpQualitySource.ipLocate,
    type: type,
    isProxy: isProxy,
    isVpn: isVpn,
    isTor: isTor,
    isAbuser: isAbuser,
  );
}

void main() {
  test('legacy JSON does not invent access classification evidence', () {
    final json = Map<String, dynamic>.from(
      _quality(IpType.residential).toJson(),
    )..remove('typeIsInferred');
    final record = IpQuality.fromJson(json);
    expect(record.typeIsInferred, isNull);
  });

  test('reported and inferred access evidence survive JSON persistence', () {
    for (final inferred in [true, false]) {
      final quality = _quality(
        IpType.residential,
      ).copyWith(typeIsInferred: inferred);
      final decoded = IpQuality.fromJson(
        jsonDecode(jsonEncode(quality.toJson())) as Map<String, dynamic>,
      );
      expect(decoded, quality);
    }
  });

  group('IpQuality.level', () {
    test('rates residential, mobile and business addresses good', () {
      for (final type in [IpType.residential, IpType.mobile, IpType.business]) {
        expect(_quality(type).level, IpQualityLevel.good);
      }
    });

    test('rates data center addresses normal even when flagged as VPN', () {
      expect(_quality(IpType.hosting).level, IpQualityLevel.normal);
      expect(
        _quality(IpType.hosting, isProxy: true, isVpn: true).level,
        IpQualityLevel.normal,
      );
    });

    test('rates Tor exits and abusers risky whatever their type', () {
      expect(
        _quality(IpType.residential, isTor: true).level,
        IpQualityLevel.risky,
      );
      expect(
        _quality(IpType.business, isAbuser: true).level,
        IpQualityLevel.risky,
      );
    });
  });
}

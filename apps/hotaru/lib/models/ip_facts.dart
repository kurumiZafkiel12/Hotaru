import 'package:freezed_annotation/freezed_annotation.dart';

part 'generated/ip_facts.freezed.dart';
part 'generated/ip_facts.g.dart';

enum IpOrigin { native, broadcast, unknown }

enum IpAttribute { hosting, residential, mobile, business, unknown }

enum IpRisk { low, medium, elevated, high, unknown }

enum IpFactStatus { available, noData, unavailable, rateLimited }

@freezed
abstract class IpFacts with _$IpFacts {
  const IpFacts._();

  const factory IpFacts({
    required String ip,
    required DateTime checkedAt,
    DateTime? locationCheckedAt,
    DateTime? registryCheckedAt,
    DateTime? scoreCheckedAt,
    String? geoCountry,
    String? registeredCountry,
    @Default(IpAttribute.unknown) IpAttribute attribute,
    int? riskScore,
    String? organization,
    int? asn,
    @Default(IpFactStatus.unavailable) IpFactStatus locationStatus,
    @Default(IpFactStatus.unavailable) IpFactStatus registryStatus,
    @Default(IpFactStatus.unavailable) IpFactStatus scoreStatus,
  }) = _IpFacts;

  factory IpFacts.fromJson(Map<String, Object?> json) =>
      _$IpFactsFromJson(json);

  IpOrigin get origin {
    if (geoCountry == null ||
        registeredCountry == null ||
        locationStatus != IpFactStatus.available ||
        registryStatus != IpFactStatus.available) {
      return IpOrigin.unknown;
    }
    return geoCountry == registeredCountry
        ? IpOrigin.native
        : IpOrigin.broadcast;
  }

  IpRisk get risk {
    final score = riskScore;
    if (scoreStatus != IpFactStatus.available ||
        score == null ||
        score < 0 ||
        score > 100) {
      return IpRisk.unknown;
    }
    return switch (score) {
      < 20 => IpRisk.low,
      < 60 => IpRisk.medium,
      < 90 => IpRisk.elevated,
      _ => IpRisk.high,
    };
  }

  DateTime get expiresAt {
    DateTime expiry(DateTime? at, IpFactStatus status) => (at ?? checkedAt).add(
      status == IpFactStatus.available
          ? const Duration(days: 1)
          : const Duration(minutes: 5),
    );
    final values = [
      expiry(locationCheckedAt, locationStatus),
      expiry(registryCheckedAt, registryStatus),
      expiry(scoreCheckedAt, scoreStatus),
    ]..sort();
    return values.first;
  }
}

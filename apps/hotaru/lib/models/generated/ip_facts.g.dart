// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../ip_facts.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_IpFacts _$IpFactsFromJson(Map<String, dynamic> json) => _IpFacts(
  ip: json['ip'] as String,
  checkedAt: DateTime.parse(json['checkedAt'] as String),
  locationCheckedAt: json['locationCheckedAt'] == null
      ? null
      : DateTime.parse(json['locationCheckedAt'] as String),
  registryCheckedAt: json['registryCheckedAt'] == null
      ? null
      : DateTime.parse(json['registryCheckedAt'] as String),
  scoreCheckedAt: json['scoreCheckedAt'] == null
      ? null
      : DateTime.parse(json['scoreCheckedAt'] as String),
  geoCountry: json['geoCountry'] as String?,
  registeredCountry: json['registeredCountry'] as String?,
  attribute:
      $enumDecodeNullable(_$IpAttributeEnumMap, json['attribute']) ??
      IpAttribute.unknown,
  riskScore: (json['riskScore'] as num?)?.toInt(),
  organization: json['organization'] as String?,
  asn: (json['asn'] as num?)?.toInt(),
  locationStatus:
      $enumDecodeNullable(_$IpFactStatusEnumMap, json['locationStatus']) ??
      IpFactStatus.unavailable,
  registryStatus:
      $enumDecodeNullable(_$IpFactStatusEnumMap, json['registryStatus']) ??
      IpFactStatus.unavailable,
  scoreStatus:
      $enumDecodeNullable(_$IpFactStatusEnumMap, json['scoreStatus']) ??
      IpFactStatus.unavailable,
);

Map<String, dynamic> _$IpFactsToJson(_IpFacts instance) => <String, dynamic>{
  'ip': instance.ip,
  'checkedAt': instance.checkedAt.toIso8601String(),
  'locationCheckedAt': instance.locationCheckedAt?.toIso8601String(),
  'registryCheckedAt': instance.registryCheckedAt?.toIso8601String(),
  'scoreCheckedAt': instance.scoreCheckedAt?.toIso8601String(),
  'geoCountry': instance.geoCountry,
  'registeredCountry': instance.registeredCountry,
  'attribute': _$IpAttributeEnumMap[instance.attribute]!,
  'riskScore': instance.riskScore,
  'organization': instance.organization,
  'asn': instance.asn,
  'locationStatus': _$IpFactStatusEnumMap[instance.locationStatus]!,
  'registryStatus': _$IpFactStatusEnumMap[instance.registryStatus]!,
  'scoreStatus': _$IpFactStatusEnumMap[instance.scoreStatus]!,
};

const _$IpAttributeEnumMap = {
  IpAttribute.hosting: 'hosting',
  IpAttribute.residential: 'residential',
  IpAttribute.mobile: 'mobile',
  IpAttribute.business: 'business',
  IpAttribute.unknown: 'unknown',
};

const _$IpFactStatusEnumMap = {
  IpFactStatus.available: 'available',
  IpFactStatus.noData: 'noData',
  IpFactStatus.unavailable: 'unavailable',
  IpFactStatus.rateLimited: 'rateLimited',
};

// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../routing_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_RoutingConfig _$RoutingConfigFromJson(Map<String, dynamic> json) =>
    _RoutingConfig(
      id: (json['id'] as num).toInt(),
      name: json['name'] as String,
      url: json['url'] as String,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      digest: json['digest'] as String,
      ruleCount: (json['ruleCount'] as num).toInt(),
    );

Map<String, dynamic> _$RoutingConfigToJson(_RoutingConfig instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'url': instance.url,
      'updatedAt': instance.updatedAt.toIso8601String(),
      'digest': instance.digest,
      'ruleCount': instance.ruleCount,
    };

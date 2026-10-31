import 'package:freezed_annotation/freezed_annotation.dart';

part 'generated/routing_config.freezed.dart';
part 'generated/routing_config.g.dart';

@freezed
abstract class RoutingConfig with _$RoutingConfig {
  const factory RoutingConfig({
    required int id,
    required String name,
    required String url,
    required DateTime updatedAt,
    required String digest,
    required int ruleCount,
  }) = _RoutingConfig;

  factory RoutingConfig.fromJson(Map<String, dynamic> json) =>
      _$RoutingConfigFromJson(json);
}

enum CoreProviderKind { proxy, rule }

enum CoreProviderVehicle { http, file }

final class CoreProviderInfo {
  final String name;
  final CoreProviderKind kind;
  final CoreProviderVehicle vehicle;
  final String? path;
  final int count;
  final DateTime loadedAt;
  final Duration interval;

  const CoreProviderInfo({
    required this.name,
    required this.kind,
    required this.vehicle,
    required this.path,
    required this.count,
    required this.loadedAt,
    required this.interval,
  });
}

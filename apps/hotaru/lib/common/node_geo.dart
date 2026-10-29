import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hotaru/models/models.dart';

import 'network_diagnostics.dart';

const nodeGeoSource = 'https://get.geojs.io/v1/ip/geo.json';

class NodeGeoTarget {
  const NodeGeoTarget({required this.name, required this.server});
  final String name;
  final String server;

  static List<NodeGeoTarget> fromProxies(ProxiesData data) => [
    for (final entry in data.proxies.entries)
      if (entry.value case final Map value)
        if (value['all'] is! List &&
            !const {
              'Direct',
              'Reject',
              'RejectDrop',
              'Pass',
              'Compatible',
              'Selector',
              'URLTest',
              'Fallback',
              'LoadBalance',
              'Relay',
            }.contains(value['type']))
          NodeGeoTarget(
            name: entry.key,
            server: value['entry-server'] is String
                ? value['entry-server'] as String
                : '',
          ),
  ];
}

class NodeGeoLocation {
  const NodeGeoLocation({
    required this.ip,
    required this.country,
    required this.city,
    required this.organization,
    required this.asn,
    required this.latitude,
    required this.longitude,
  });
  final String ip;
  final String country;
  final String city;
  final String organization;
  final String asn;
  final double latitude;
  final double longitude;

  factory NodeGeoLocation.parse(String body) {
    final json = jsonDecode(body);
    if (json is! Map) throw const FormatException('invalid GeoJS response');
    final ip = InternetAddress.tryParse('${json['ip'] ?? ''}');
    final lat = double.tryParse('${json['latitude']}');
    final lon = double.tryParse('${json['longitude']}');
    if (ip == null ||
        !isPublicProbeAddress(ip) ||
        lat == null ||
        lon == null ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      throw const FormatException('missing or invalid IP position');
    }
    final country = '${json['country_code'] ?? ''}'.toUpperCase();
    return NodeGeoLocation(
      ip: ip.address,
      country: RegExp(r'^[A-Z]{2}$').hasMatch(country) ? country : '',
      city: '${json['city'] ?? ''}',
      organization:
          '${json['organization_name'] ?? json['organization'] ?? ''}',
      asn: '${json['asn'] ?? ''}',
      latitude: lat,
      longitude: lon,
    );
  }
}

class NodeGeoObservation {
  const NodeGeoObservation({
    required this.target,
    required this.checkedAt,
    required this.routeKey,
    this.location,
    this.entryAddresses = const [],
    this.chains = const [],
    this.error,
  });
  final NodeGeoTarget target;
  final DateTime checkedAt;
  final String routeKey;
  final NodeGeoLocation? location;
  final List<String> entryAddresses;
  final List<String> chains;
  final String? error;
}

class NodeGeoCache {
  final _items = <String, NodeGeoObservation>{};
  static const maxAge = Duration(minutes: 15);
  NodeGeoObservation? read(String key, DateTime now) {
    final item = _items[key];
    if (item == null ||
        item.checkedAt.isAfter(now) ||
        now.difference(item.checkedAt) >= maxAge) {
      return null;
    }
    return item;
  }

  void write(String key, NodeGeoObservation value) {
    if (_items.length >= 2000) _items.remove(_items.keys.first);
    _items[key] = value;
  }
}

class NodeGeoRunner {
  NodeGeoRunner({
    required this.probe,
    required this.cache,
    required this.routeKey,
    required this.coreEpoch,
    required this.routeVersion,
    Future<List<InternetAddress>> Function(String)? lookup,
    this.interval = const Duration(seconds: 1),
  }) : lookup = lookup ?? InternetAddress.lookup;

  final Future<OutboundIpResult?> Function(String node) probe;
  final Future<List<InternetAddress>> Function(String host) lookup;
  final NodeGeoCache cache;
  final String routeKey;
  final Duration interval;
  final int coreEpoch;
  final int routeVersion;
  bool _cancelled = false;
  DateTime _next = DateTime.now();

  void cancel() => _cancelled = true;

  Future<void> run(
    List<NodeGeoTarget> nodes, {
    required void Function(NodeGeoObservation) onResult,
    bool force = false,
  }) async {
    var cursor = 0;
    Future<void> worker() async {
      while (!_cancelled && cursor < nodes.length) {
        final target = nodes[cursor++];
        final key = '$routeKey/${target.name}/${target.server}';
        final cached = force ? null : cache.read(key, DateTime.now());
        if (cached != null) {
          onResult(cached);
          continue;
        }
        NodeGeoObservation? observation;
        for (var attempt = 0; attempt < 2 && !_cancelled; attempt++) {
          try {
            final now = DateTime.now();
            if (_next.isBefore(now)) _next = now;
            final wait = _next.difference(now);
            _next = _next.add(interval);
            if (wait > Duration.zero) await Future<void>.delayed(wait);
            if (_cancelled) return;
            final result = await probe(target.name);
            if (_cancelled) return;
            if (result == null ||
                result.error != null ||
                result.coreEpoch != coreEpoch ||
                result.routeVersion != routeVersion ||
                !result.chains.contains(target.name)) {
              throw const FormatException('node route not verified');
            }
            final location = NodeGeoLocation.parse(result.body);
            if (result.url != nodeGeoSource) {
              throw const FormatException('unexpected GeoIP source');
            }
            var entries = const <String>[];
            if (target.server.isNotEmpty) {
              try {
                final addresses = await lookup(
                  target.server,
                ).timeout(const Duration(seconds: 4));
                entries = addresses
                    .where(isPublicProbeAddress)
                    .map((address) => address.address)
                    .toSet()
                    .take(8)
                    .toList();
              } on Object {
                entries = const [];
              }
            }
            observation = NodeGeoObservation(
              target: target,
              checkedAt: DateTime.now(),
              routeKey: routeKey,
              location: location,
              entryAddresses: entries,
              chains: result.chains,
            );
            break;
          } catch (_) {
            observation = NodeGeoObservation(
              target: target,
              checkedAt: DateTime.now(),
              routeKey: routeKey,
              error: 'GeoIP response or node route unavailable',
            );
            if (attempt == 0 && !_cancelled) {
              await Future<void>.delayed(interval);
            }
          }
        }
        if (_cancelled) return;
        if (observation != null) {
          if (observation.location != null) cache.write(key, observation);
          onResult(observation);
        }
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
  }
}

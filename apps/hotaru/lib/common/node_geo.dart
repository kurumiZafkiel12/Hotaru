import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';

/// Coordinates one geolocation source reports for an address.
class GeoCoordinates {
  const GeoCoordinates({
    required this.countryCode,
    required this.city,
    required this.latitude,
    required this.longitude,
  });

  final String countryCode;
  final String city;
  final double latitude;
  final double longitude;
}

Map<String, dynamic>? _asMap(Object? data) {
  Object? decoded;
  try {
    decoded = data is String ? jsonDecode(data) : data;
  } on FormatException {
    return null;
  }
  return decoded is Map<String, dynamic> ? decoded : null;
}

double? _coordinate(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value');
}

GeoCoordinates? parseIpWhoCoordinates(Object? data) {
  final json = _asMap(data);
  if (json == null || json['success'] == false) return null;
  final latitude = _coordinate(json['latitude']);
  final longitude = _coordinate(json['longitude']);
  final country = '${json['country_code'] ?? ''}';
  if (latitude == null || longitude == null || country.isEmpty) return null;
  return GeoCoordinates(
    countryCode: country,
    city: '${json['city'] ?? ''}',
    latitude: latitude,
    longitude: longitude,
  );
}

GeoCoordinates? parseIpApiCoordinates(Object? data) {
  final json = _asMap(data);
  if (json == null || json['status'] != 'success') return null;
  final latitude = _coordinate(json['lat']);
  final longitude = _coordinate(json['lon']);
  final country = '${json['countryCode'] ?? ''}';
  if (latitude == null || longitude == null || country.isEmpty) return null;
  return GeoCoordinates(
    countryCode: country,
    city: '${json['city'] ?? ''}',
    latitude: latitude,
    longitude: longitude,
  );
}

/// Locates one exit address: ipwho.is first, ip-api as the fallback.
Future<GeoCoordinates?> lookupCoordinates(
  Dio dio,
  String ip, {
  CancelToken? cancelToken,
}) async {
  final options = Options(
    responseType: ResponseType.plain,
    receiveTimeout: const Duration(seconds: 6),
    sendTimeout: const Duration(seconds: 6),
  );
  try {
    final response = await dio.get<String>(
      'https://ipwho.is/$ip',
      options: options,
      cancelToken: cancelToken,
    );
    final parsed = parseIpWhoCoordinates(response.data);
    if (parsed != null) return parsed;
  } catch (_) {
    // Fall through to the second source.
  }
  try {
    final response = await dio.get<String>(
      'http://ip-api.com/json/$ip?fields=status,countryCode,city,lat,lon',
      options: options,
      cancelToken: cancelToken,
    );
    return parseIpApiCoordinates(response.data);
  } catch (_) {
    return null;
  }
}

/// A node whose exit has been located.
class NodeGeo {
  const NodeGeo({
    required this.name,
    required this.type,
    required this.ip,
    required this.coordinates,
  });

  final String name;
  final String type;
  final String ip;
  final GeoCoordinates coordinates;
}

/// Nodes sharing a place, aggregated onto one globe point.
class GeoCluster {
  const GeoCluster({
    required this.latitude,
    required this.longitude,
    required this.city,
    required this.countryCode,
    required this.nodes,
  });

  final double latitude;
  final double longitude;
  final String city;
  final String countryCode;
  final List<NodeGeo> nodes;
}

/// Groups located nodes by place: a node joins the first cluster
/// whose members average within about a degree of it, so neighbors
/// never split across a cell boundary. A cluster sits at its
/// members' average position and takes the first named city.
List<GeoCluster> clusterNodeGeos(List<NodeGeo> geos) {
  final cells = <List<NodeGeo>>[];
  for (final geo in geos) {
    List<NodeGeo>? home;
    for (final cell in cells) {
      final latitude =
          cell.fold(0.0, (sum, node) => sum + node.coordinates.latitude) /
          cell.length;
      final longitude =
          cell.fold(0.0, (sum, node) => sum + node.coordinates.longitude) /
          cell.length;
      if ((geo.coordinates.latitude - latitude).abs() <= 1.1 &&
          (geo.coordinates.longitude - longitude).abs() <= 1.1) {
        home = cell;
        break;
      }
    }
    if (home == null) {
      home = [geo];
      cells.add(home);
    } else {
      home.add(geo);
    }
  }
  final clusters = [
    for (final nodes in cells)
      GeoCluster(
        latitude:
            nodes.fold(0.0, (sum, node) => sum + node.coordinates.latitude) /
            nodes.length,
        longitude:
            nodes.fold(0.0, (sum, node) => sum + node.coordinates.longitude) /
            nodes.length,
        city: nodes
            .map((node) => node.coordinates.city)
            .firstWhere((city) => city.isNotEmpty, orElse: () => ''),
        countryCode: nodes.first.coordinates.countryCode,
        nodes: nodes,
      ),
  ];
  clusters.sort((a, b) => b.nodes.length.compareTo(a.nodes.length));
  return clusters;
}

/// Orthographic projection for the globe: [yawDegrees] spins the
/// earth east, [pitchDegrees] tilts it. Returns the screen position
/// and the depth (positive toward the viewer), or null when the
/// point sits on the far side.
({Offset offset, double depth})? projectGlobe({
  required double latitude,
  required double longitude,
  required double yawDegrees,
  required double pitchDegrees,
  required Size size,
  required double zoom,
}) {
  final phi = latitude * math.pi / 180;
  final lambda = (longitude + yawDegrees) * math.pi / 180;
  final pitch = pitchDegrees * math.pi / 180;
  final x = math.cos(phi) * math.sin(lambda);
  final y = math.sin(phi);
  final z = math.cos(phi) * math.cos(lambda);
  final tiltedY = y * math.cos(pitch) - z * math.sin(pitch);
  final tiltedZ = y * math.sin(pitch) + z * math.cos(pitch);
  if (tiltedZ <= 0) return null;
  final radius = math.min(size.width, size.height) / 2 * zoom;
  final center = Offset(size.width / 2, size.height / 2);
  return (
    offset: center + Offset(x * radius, -tiltedY * radius),
    depth: tiltedZ,
  );
}

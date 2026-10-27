import 'dart:convert';

import 'package:hotaru/common/earth_grid.dart';
import 'package:hotaru/common/node_geo.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('coordinate parsers', () {
    test('ipwho.is', () {
      final parsed = parseIpWhoCoordinates(
        jsonEncode({
          'country_code': 'JP',
          'city': 'Tokyo',
          'latitude': 35.6895,
          'longitude': 139.6917,
        }),
      );
      expect(parsed?.countryCode, 'JP');
      expect(parsed?.latitude, closeTo(35.69, 0.01));
      expect(parseIpWhoCoordinates('{"success": false}'), isNull);
    });

    test('ip-api', () {
      final parsed = parseIpApiCoordinates(
        jsonEncode({
          'status': 'success',
          'countryCode': 'US',
          'city': 'Ashburn',
          'lat': 39.03,
          'lon': -77.5,
        }),
      );
      expect(parsed?.city, 'Ashburn');
      expect(parseIpApiCoordinates('{"status": "fail"}'), isNull);
    });
  });

  test('the land grid knows the continents from the oceans', () {
    int cellOf(double lon, double lat) {
      final col = ((lon + 180) / landGridStepDegrees).floor();
      final row = ((90 - lat) / landGridStepDegrees).floor();
      return isLandGridCell(col, row) ? 1 : 0;
    }

    expect(cellOf(139.7, 35.7), 1, reason: 'Tokyo');
    expect(cellOf(116.4, 39.9), 1, reason: 'Beijing');
    expect(cellOf(-0.1, 51.5), 1, reason: 'London');
    expect(cellOf(151.2, -33.9), 1, reason: 'Sydney');
    expect(cellOf(-160, 0), 0, reason: 'mid-Pacific');
    expect(cellOf(-30, -20), 0, reason: 'south Atlantic');
  });

  test('clustering aggregates a place and averages its position', () {
    NodeGeo node(String name, double lat, double lon, String city) => NodeGeo(
      name: name,
      type: 'ss',
      ip: '203.0.113.1',
      coordinates: GeoCoordinates(
        countryCode: 'JP',
        city: city,
        latitude: lat,
        longitude: lon,
      ),
    );
    final clusters = clusterNodeGeos([
      node('a', 35.6, 139.7, 'Tokyo'),
      node('b', 35.7, 139.8, 'Tokyo'),
      node('c', 34.7, 135.5, 'Osaka'),
    ]);
    expect(clusters, hasLength(2));
    expect(clusters.first.nodes, hasLength(2));
    expect(clusters.first.city, 'Tokyo');
    expect(clusters.first.latitude, closeTo(35.65, 0.01));
  });

  group('globe projection', () {
    const size = Size(400, 400);

    test('the facing center projects to the middle', () {
      final point = projectGlobe(
        latitude: 0,
        longitude: 115,
        yawDegrees: -115,
        pitchDegrees: 0,
        size: size,
        zoom: 1,
      );
      expect(point, isNotNull);
      expect(point!.offset.dx, closeTo(200, 0.01));
      expect(point.offset.dy, closeTo(200, 0.01));
      expect(point.depth, closeTo(1, 0.001));
    });

    test('the far side is hidden', () {
      expect(
        projectGlobe(
          latitude: 0,
          longitude: -65,
          yawDegrees: -115,
          pitchDegrees: 0,
          size: size,
          zoom: 1,
        ),
        isNull,
      );
    });
  });
}

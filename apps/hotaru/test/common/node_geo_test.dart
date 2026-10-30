import 'dart:convert';
import 'dart:io';

import 'package:hotaru/common/node_geo.dart';
import 'package:hotaru/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

String payload({Object latitude = 35, Object longitude = 139}) => jsonEncode({
  'ip': '8.8.8.8',
  'country_code': 'JP',
  'city': 'Example',
  'organization_name': 'Example Network',
  'asn': 64500,
  'latitude': latitude,
  'longitude': longitude,
});

void main() {
  test('entry servers remain separate from observed exit coordinates', () {
    final nodes = NodeGeoTarget.fromProxies(
      const ProxiesData(
        all: [],
        proxies: {
          'DIRECT': {'type': 'Direct'},
          'Group': {
            'type': 'Selector',
            'all': ['A'],
          },
          'A': {'type': 'Vless', 'entry-server': 'entry.example'},
        },
      ),
    );
    expect(nodes.map((node) => node.name), ['A']);
    expect(nodes.single.server, 'entry.example');
    final geo = NodeGeoLocation.parse(payload());
    expect(geo.ip, '8.8.8.8');
    expect(geo.latitude, 35);
    expect(geo.longitude, 139);
    expect(
      () => NodeGeoLocation.parse(payload(latitude: 'NaN')),
      throwsFormatException,
    );
    expect(
      () => NodeGeoLocation.parse(payload(longitude: 181)),
      throwsFormatException,
    );
    expect(() => NodeGeoLocation.parse('{}'), throwsFormatException);
  });

  test(
    'bounded workers pin each node and successful cache entries avoid another probe',
    () async {
      final calls = <String>[];
      var running = 0;
      var peak = 0;
      final cache = NodeGeoCache();
      final nodes = [
        for (var i = 0; i < 9; i++)
          NodeGeoTarget(name: 'node-$i', server: 'entry.example'),
      ];
      NodeGeoRunner runner() => NodeGeoRunner(
        cache: cache,
        routeKey: 'route1',
        coreEpoch: 1,
        routeVersion: 1,
        interval: Duration.zero,
        lookup: (_) async => [InternetAddress('1.1.1.1')],
        probe: (node) async {
          calls.add(node);
          running++;
          if (running > peak) peak = running;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          running--;
          return OutboundIpResult(
            url: nodeGeoSource,
            coreEpoch: 1,
            routeVersion: 1,
            body: payload(),
            chains: [node],
          );
        },
      );
      final results = <NodeGeoObservation>[];
      await runner().run(nodes, onResult: results.add);
      expect(peak, lessThanOrEqualTo(3));
      expect(calls, unorderedEquals(nodes.map((node) => node.name)));
      expect(
        results.every(
          (result) =>
              result.entryAddresses.single == '1.1.1.1' &&
              result.location!.ip == '8.8.8.8',
        ),
        isTrue,
      );
      expect(results.every((result) => result.routeKey == 'route1'), isTrue);
      calls.clear();
      results.clear();
      await runner().run(nodes, onResult: results.add);
      expect(calls, isEmpty);
      expect(results, hasLength(9));
    },
  );

  test(
    'a different route or malformed location cannot become a map result',
    () async {
      var calls = 0;
      final results = <NodeGeoObservation>[];
      final runner = NodeGeoRunner(
        cache: NodeGeoCache(),
        routeKey: 'route',
        coreEpoch: 1,
        routeVersion: 1,
        interval: Duration.zero,
        probe: (_) async {
          calls++;
          return OutboundIpResult(
            url: nodeGeoSource,
            coreEpoch: 1,
            routeVersion: 1,
            body: payload(),
            chains: const ['wrong-node'],
          );
        },
      );
      await runner.run(const [
        NodeGeoTarget(name: 'selected-node', server: ''),
      ], onResult: results.add);
      expect(calls, 2);
      expect(results.single.location, isNull);
      expect(results.single.error, isNotNull);
    },
  );

  test('cancel ignores pending responses and does not cache them', () async {
    final cache = NodeGeoCache();
    final calls = <String>[];
    final results = <NodeGeoObservation>[];
    late NodeGeoRunner runner;
    runner = NodeGeoRunner(
      cache: cache,
      routeKey: 'route',
      coreEpoch: 1,
      routeVersion: 1,
      interval: Duration.zero,
      probe: (name) async {
        calls.add(name);
        runner.cancel();
        return OutboundIpResult(
          url: nodeGeoSource,
          coreEpoch: 1,
          routeVersion: 1,
          body: payload(),
          chains: [name],
        );
      },
    );
    await runner.run(const [
      NodeGeoTarget(name: 'A', server: ''),
    ], onResult: results.add);
    expect(results, isEmpty);
    expect(cache.read('route/A/', DateTime.now()), isNull);
  });

  test('cached positions expire and do not survive a backwards clock', () {
    final cache = NodeGeoCache();
    final time = DateTime.utc(2026, 10, 29);
    cache.write(
      'key',
      NodeGeoObservation(
        target: const NodeGeoTarget(name: 'A', server: ''),
        checkedAt: time,
        routeKey: 'route',
      ),
    );
    expect(cache.read('key', time.add(const Duration(minutes: 14))), isNotNull);
    expect(cache.read('key', time.add(const Duration(minutes: 15))), isNull);
    expect(
      cache.read('key', time.subtract(const Duration(seconds: 1))),
      isNull,
    );
  });
}

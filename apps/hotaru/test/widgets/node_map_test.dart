import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/ui/node_globe.dart';
import 'package:hotaru/ui/node_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/map_tiles.dart';

void main() {
  testWidgets(
    'detailed map preserves each IP coordinate and supports zoom and selection',
    (tester) async {
      final tiles = FixtureMapTiles();
      List<String>? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NodeMap(
              markers: [
                GlobeMarker(id: 'tokyo', latitude: 35.681, longitude: 139.767),
                GlobeMarker(id: 'osaka', latitude: 34.693, longitude: 135.502),
              ],
              labels: const {'tokyo': '203.0.113.1', 'osaka': '203.0.113.2'},
              focus: const GlobeFocus(35.681, 139.767),
              tileProvider: tiles,
              onSelected: (ids) => selected = ids,
              onAttribution: () {},
              unavailableLabel: '地图暂不可用',
              retryLabel: '重试',
              zoomInLabel: '放大地图',
              zoomOutLabel: '缩小地图',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final markers = tester
          .widget<MarkerLayer>(find.byType(MarkerLayer))
          .markers;
      expect(markers.map((marker) => marker.point), [
        const LatLng(35.681, 139.767),
        const LatLng(34.693, 135.502),
      ]);
      await tester.tap(find.text('203.0.113.1'));
      expect(selected, ['tokyo']);
      final controller = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!;
      final zoom = controller.camera.zoom;
      await tester.tap(find.byTooltip('放大地图'));
      await tester.pumpAndSettle();
      expect(controller.camera.zoom, zoom + 1);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('tile failure has a retry without losing the IP marker', (
    tester,
  ) async {
    final tiles = FixtureMapTiles()..failing = true;
    final imageErrors = <FlutterErrorDetails>[];
    final previousErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString() == 'Exception: Invalid image data') {
        imageErrors.add(details);
      } else {
        previousErrorHandler?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = previousErrorHandler);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NodeMap(
            markers: [GlobeMarker(id: 'a', latitude: 35, longitude: 139)],
            labels: const {'a': '203.0.113.1'},
            tileProvider: tiles,
            onSelected: (_) {},
            onAttribution: () {},
            unavailableLabel: 'Map unavailable',
            retryLabel: 'Retry',
            zoomInLabel: 'Zoom in',
            zoomOutLabel: 'Zoom out',
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(imageErrors, isNotEmpty);
    expect(find.text('Map unavailable'), findsOneWidget);
    expect(find.text('203.0.113.1'), findsOneWidget);
    tiles.failing = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Map unavailable'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('co-located IPs remain at the shared real coordinate', (
    tester,
  ) async {
    List<String>? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NodeMap(
            markers: [
              GlobeMarker(id: 'a', latitude: 35, longitude: 139),
              GlobeMarker(id: 'b', latitude: 35, longitude: 139),
            ],
            labels: const {'a': '203.0.113.1', 'b': '203.0.113.2'},
            tileProvider: FixtureMapTiles(),
            onSelected: (ids) => selected = ids,
            onAttribution: () {},
            unavailableLabel: 'Map unavailable',
            retryLabel: 'Retry',
            zoomInLabel: 'Zoom in',
            zoomOutLabel: 'Zoom out',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final markers = tester
        .widget<MarkerLayer>(find.byType(MarkerLayer))
        .markers;
    expect(markers, hasLength(1));
    expect(markers.single.point, const LatLng(35, 139));
    await tester.tap(find.text('2 IP'));
    expect(selected, ['a', 'b']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

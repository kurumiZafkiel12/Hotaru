import 'package:hotaru/ui/node_globe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const size = Size.square(400);
  test(
    'the sphere centers the selected location and hides its far hemisphere',
    () {
      const camera = GlobeCamera(latitude: 0, longitude: 0);
      final center = GlobeMarker(id: 'center', latitude: 0, longitude: 0);
      final far = GlobeMarker(id: 'far', latitude: 0, longitude: 180);
      expect(camera.project(center.vector, size), const Offset(200, 200));
      expect(camera.project(far.vector, size), isNull);
      final point = GlobeMarker(id: 'focus', latitude: 45, longitude: 90);
      final focused = const GlobeCamera(
        latitude: 45,
        longitude: 90,
      ).project(point.vector, size)!;
      expect(focused.dx, closeTo(200, 1e-6));
      expect(focused.dy, closeTo(200, 1e-6));
    },
  );

  testWidgets('zooming into the globe requests detailed map coordinates', (
    tester,
  ) async {
    GlobeFocus? requested;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NodeGlobe(
            markers: const [],
            label: 'Globe',
            onSelected: (_) {},
            onDetailRequested: (focus) => requested = focus,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(400, 300),
        scrollDelta: Offset(0, -1000),
      ),
    );
    await tester.pump();
    expect(requested, isNotNull);
    expect(requested!.latitude, 15);
    expect(requested!.longitude, 100);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('hundreds of co-located nodes cluster without inventing positions', () {
    final markers = [
      for (var i = 0; i < 500; i++)
        GlobeMarker(id: '$i', latitude: 0, longitude: 0),
    ];
    final clusters = clusterGlobeMarkers(
      markers,
      const GlobeCamera(latitude: 0, longitude: 0),
      size,
    );
    expect(clusters, hasLength(1));
    expect(clusters.single.markers, hasLength(500));
    expect(clusters.single.position, const Offset(200, 200));
    expect(
      clusterGlobeMarkers(
        markers,
        const GlobeCamera(latitude: 0, longitude: 180),
        size,
      ),
      isEmpty,
    );
  });

  test('the 2D fallback retains coordinates and date-line wrapping', () {
    final projection = GlobeProjection(
      const GlobeCamera(latitude: 0, longitude: 179),
      size,
      flat: true,
    );
    expect(
      projection.coordinates(0, -179).dx,
      closeTo(200 + 400 * 2 / 360, 1e-6),
    );
    expect(projection.coordinates(45, 179).dy, 100);
  });
}

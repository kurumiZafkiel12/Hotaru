import 'package:hotaru/ui/node_globe.dart';
import 'package:flutter_test/flutter_test.dart';
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

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'typography.dart';

class GlobeMarker {
  GlobeMarker({
    required this.id,
    required this.latitude,
    required this.longitude,
  }) : vector = _vector(latitude, longitude);
  final String id;
  final double latitude;
  final double longitude;
  final List<double> vector;
}

class GlobeFocus {
  const GlobeFocus(this.latitude, this.longitude);
  final double latitude;
  final double longitude;
}

class GlobeCamera {
  const GlobeCamera({this.latitude = 15, this.longitude = 100, this.zoom = 1});
  final double latitude;
  final double longitude;
  final double zoom;

  Offset? project(List<double> vector, Size size, {bool flat = false}) =>
      GlobeProjection(
        this,
        size,
        flat: flat,
      ).project(vector[0], vector[1], vector[2]);
}

class GlobeProjection {
  GlobeProjection(this.camera, this.size, {this.flat = false})
    : sy = math.sin(camera.longitude * math.pi / 180),
      cy = math.cos(camera.longitude * math.pi / 180),
      sp = math.sin(camera.latitude * math.pi / 180),
      cp = math.cos(camera.latitude * math.pi / 180),
      radius = math.min(size.width, size.height) * 0.45 * camera.zoom;
  final GlobeCamera camera;
  final Size size;
  final bool flat;
  final double sy, cy, sp, cp, radius;

  Offset coordinates(double latitude, double longitude) {
    final dx = ((longitude - camera.longitude + 540) % 360) - 180;
    return Offset(
      size.width / 2 + dx / 360 * size.width * camera.zoom,
      size.height / 2 -
          (latitude - camera.latitude) / 180 * size.height * camera.zoom,
    );
  }

  Offset? project(double vx, double vy, double vz) {
    if (flat) {
      return coordinates(
        math.asin(vy.clamp(-1.0, 1.0)) * 180 / math.pi,
        math.atan2(vx, vz) * 180 / math.pi,
      );
    }
    final x = cy * vx - sy * vz;
    final z = sy * vx + cy * vz;
    final y = cp * vy - sp * z;
    if (sp * vy + cp * z < -1e-9) return null;
    return Offset(size.width / 2 + x * radius, size.height / 2 - y * radius);
  }
}

List<double> _vector(double latitude, double longitude) {
  final lat = latitude * math.pi / 180;
  final lon = longitude * math.pi / 180;
  return [
    math.cos(lat) * math.sin(lon),
    math.sin(lat),
    math.cos(lat) * math.cos(lon),
  ];
}

List<Float32List> _parseLand(String raw) {
  final result = <Float32List>[];
  final json = jsonDecode(raw) as Map;
  for (final feature in json['features'] as List) {
    final geometry = feature['geometry'] as Map;
    final polygons = geometry['type'] == 'Polygon'
        ? [geometry['coordinates']]
        : geometry['coordinates'] as List;
    for (final polygon in polygons) {
      for (final ring in polygon as List) {
        final vertices = <double>[];
        for (final coordinate in ring as List) {
          final lat = (coordinate[1] as num).toDouble();
          final lon = (coordinate[0] as num).toDouble();
          vertices.addAll([..._vector(lat, lon), lat, lon]);
        }
        result.add(Float32List.fromList(vertices));
      }
    }
  }
  return result;
}

class GlobeCluster {
  GlobeCluster(this.position, this.markers);
  final Offset position;
  final List<GlobeMarker> markers;
}

List<GlobeCluster> clusterGlobeMarkers(
  List<GlobeMarker> markers,
  GlobeCamera camera,
  Size size, {
  bool flat = false,
}) {
  final cells = <(int, int), GlobeCluster>{};
  final projection = GlobeProjection(camera, size, flat: flat);
  for (final marker in markers) {
    final point = flat
        ? projection.coordinates(marker.latitude, marker.longitude)
        : projection.project(
            marker.vector[0],
            marker.vector[1],
            marker.vector[2],
          );
    if (point == null || !(Offset.zero & size).contains(point)) continue;
    final key = ((point.dx / 24).floor(), (point.dy / 24).floor());
    (cells[key] ??= GlobeCluster(point, [])).markers.add(marker);
  }
  return cells.values.toList();
}

List<Float32List>? _landData;
final _land = rootBundle
    .loadString('assets/data/ne_110m_land.geojson')
    .then((raw) => compute(_parseLand, raw))
    .then((data) => _landData = data);

class NodeGlobe extends StatefulWidget {
  const NodeGlobe({
    super.key,
    required this.markers,
    required this.onSelected,
    required this.label,
    this.focus,
    this.flat = false,
    this.onDetailRequested,
  });
  final ValueChanged<GlobeFocus>? onDetailRequested;
  final List<GlobeMarker> markers;
  final void Function(List<String> ids) onSelected;
  final String label;
  final GlobeFocus? focus;
  final bool flat;

  @override
  State<NodeGlobe> createState() => _NodeGlobeState();
}

class _NodeGlobeState extends State<NodeGlobe>
    with SingleTickerProviderStateMixin {
  GlobeCamera _camera = const GlobeCamera();
  GlobeCamera _from = const GlobeCamera();
  GlobeCamera _to = const GlobeCamera();
  double _startZoom = 1;
  late final AnimationController _flight =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 450),
      )..addListener(() {
        final t = Curves.easeInOutCubic.transform(_flight.value);
        setState(
          () => _camera = GlobeCamera(
            latitude: _from.latitude + (_to.latitude - _from.latitude) * t,
            longitude: _from.longitude + (_to.longitude - _from.longitude) * t,
            zoom: _from.zoom + (_to.zoom - _from.zoom) * t,
          ),
        );
      });

  @override
  void didUpdateWidget(NodeGlobe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focus != oldWidget.focus) {
      final focus = widget.focus;
      if (focus != null) {
        _fly(focus.latitude, focus.longitude, math.max(1.5, _camera.zoom));
      }
    }
  }

  void _fly(double latitude, double longitude, double zoom) {
    _from = _camera;
    final delta = ((longitude - _camera.longitude + 540) % 360) - 180;
    _to = GlobeCamera(
      latitude: latitude,
      longitude: _camera.longitude + delta,
      zoom: zoom.clamp(1, 4),
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _camera = _to);
    } else {
      _flight.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (size.isEmpty) return const SizedBox.shrink();
      final clusters = clusterGlobeMarkers(
        widget.markers,
        _camera,
        size,
        flat: widget.flat,
      );
      final colors = Theme.of(context).colorScheme;
      return Semantics(
        label: widget.label,
        child: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              _flight.stop();
              setState(
                () => _camera = GlobeCamera(
                  latitude: _camera.latitude,
                  longitude: _camera.longitude,
                  zoom: (_camera.zoom * math.exp(-event.scrollDelta.dy / 600))
                      .clamp(1, 4),
                ),
              );
              if (_camera.zoom >= 2.8) {
                widget.onDetailRequested?.call(
                  GlobeFocus(_camera.latitude, _camera.longitude),
                );
              }
            }
          },
          child: GestureDetector(
            onScaleStart: (_) {
              _flight.stop();
              _startZoom = _camera.zoom;
            },
            onScaleUpdate: (details) {
              setState(
                () => _camera = GlobeCamera(
                  latitude:
                      (_camera.latitude +
                              details.focalPointDelta.dy / size.height * 150)
                          .clamp(-85, 85),
                  longitude:
                      (_camera.longitude -
                          details.focalPointDelta.dx / size.width * 180) %
                      360,
                  zoom: (_startZoom * details.scale).clamp(1, 4),
                ),
              );
              if (_camera.zoom >= 2.8) {
                widget.onDetailRequested?.call(
                  GlobeFocus(_camera.latitude, _camera.longitude),
                );
              }
            },
            onTapUp: (details) {
              GlobeCluster? nearest;
              var distance = 24.0;
              for (final cluster in clusters) {
                final gap = (details.localPosition - cluster.position).distance;
                if (gap < distance) {
                  nearest = cluster;
                  distance = gap;
                }
              }
              if (nearest != null) {
                final first = nearest.markers.first;
                if (nearest.markers.length > 1) {
                  _fly(
                    first.latitude,
                    first.longitude,
                    math.min(4, _camera.zoom * 1.7),
                  );
                }
                widget.onSelected(
                  nearest.markers.map((marker) => marker.id).toList(),
                );
              }
            },
            child: FutureBuilder<List<Float32List>>(
              future: _land,
              initialData: _landData,
              builder: (context, snapshot) => CustomPaint(
                size: size,
                painter: _GlobePainter(
                  camera: _camera,
                  flat: widget.flat,
                  land: snapshot.data ?? const [],
                  clusters: clusters,
                  colors: colors,
                  labelStyle: AppTextStyle.caption1
                      .of(context)
                      .copyWith(color: colors.onPrimary),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _GlobePainter extends CustomPainter {
  const _GlobePainter({
    required this.camera,
    required this.flat,
    required this.land,
    required this.clusters,
    required this.colors,
    required this.labelStyle,
  });
  final GlobeCamera camera;
  final bool flat;
  final List<Float32List> land;
  final List<GlobeCluster> clusters;
  final ColorScheme colors;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final radius = math.min(size.width, size.height) * 0.45 * camera.zoom;
    final center = Offset(size.width / 2, size.height / 2);
    final globe = Rect.fromCircle(center: center, radius: radius);
    if (flat) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = colors.surfaceContainer,
      );
    } else {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.4, -0.5),
            colors: [colors.primaryContainer, colors.surfaceContainer],
          ).createShader(globe),
      );
      canvas.clipPath(Path()..addOval(globe));
    }
    final projection = GlobeProjection(camera, size, flat: flat);
    void line(
      List<double> vertices,
      Color color,
      double width, {
      int stride = 3,
    }) {
      final path = Path();
      Offset? previous;
      for (var i = 0; i < vertices.length; i += stride) {
        final point = flat && stride == 5
            ? projection.coordinates(vertices[i + 3], vertices[i + 4])
            : projection.project(vertices[i], vertices[i + 1], vertices[i + 2]);
        if (point == null) {
          previous = null;
          continue;
        }
        if (previous == null || (point - previous).distance > size.width / 2) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
        previous = point;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width,
      );
    }

    final grid = colors.onSurfaceVariant.withValues(alpha: 0.12);
    for (var lat = -60; lat <= 60; lat += 30) {
      final vertices = <double>[];
      for (var lon = -180; lon <= 180; lon += 5) {
        vertices.addAll(_vector(lat.toDouble(), lon.toDouble()));
      }
      line(vertices, grid, 0.5);
    }
    for (var lon = -180; lon < 180; lon += 30) {
      final vertices = <double>[];
      for (var lat = -90; lat <= 90; lat += 5) {
        vertices.addAll(_vector(lat.toDouble(), lon.toDouble()));
      }
      line(vertices, grid, 0.5);
    }
    for (final ring in land) {
      line(ring, colors.primary.withValues(alpha: 0.48), 0.8, stride: 5);
    }
    for (final cluster in clusters) {
      final multiple = cluster.markers.length > 1;
      canvas.drawCircle(
        cluster.position,
        multiple ? 12 : 5,
        Paint()..color = colors.primary,
      );
      if (multiple) {
        final text = TextPainter(
          text: TextSpan(text: '${cluster.markers.length}', style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(
          canvas,
          cluster.position - Offset(text.width / 2, text.height / 2),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlobePainter oldDelegate) =>
      oldDelegate.camera != camera ||
      oldDelegate.flat != flat ||
      oldDelegate.land != land ||
      oldDelegate.clusters != clusters ||
      oldDelegate.colors != colors ||
      oldDelegate.labelStyle != labelStyle;
}

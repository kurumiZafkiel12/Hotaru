import 'dart:async';
import 'dart:math' as math;

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/ui/ui.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// Every node's exit, located in one batch and plotted on a turning
/// globe: points aggregate by place, the nodes behind a point are
/// listed underneath, and an exit that cannot be located stays
/// honestly unlocated.
class NodeGlobeView extends ConsumerStatefulWidget {
  const NodeGlobeView({super.key});

  @override
  ConsumerState<NodeGlobeView> createState() => _NodeGlobeViewState();
}

class _NodeGlobeViewState extends ConsumerState<NodeGlobeView> {
  static const _groupTypes = {
    'Selector',
    'URLTest',
    'Fallback',
    'LoadBalance',
    'Relay',
  };
  static const _builtinNames = {
    'DIRECT',
    'REJECT',
    'GLOBAL',
    'PASS',
    'COMPATIBLE',
    'REJECT-DROP',
  };

  final _located = <NodeGeo>[];
  final _unknown = <String>[];
  var _probed = 0;
  var _total = 0;
  var _running = false;
  var _generation = 0;
  String? _error;

  var _flat = false;
  var _yaw = -115.0;
  var _pitch = 16.0;
  var _zoom = 0.92;
  var _autoRotate = true;
  GeoCluster? _selected;
  Timer? _spin;

  double _gestureYaw = -115;
  double _gesturePitch = 16;
  double _gestureZoom = 0.92;

  @override
  void initState() {
    super.initState();
    _spin = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (mounted && _autoRotate && !_flat && _located.isNotEmpty) {
        setState(() => _yaw += 0.12);
      }
    });
    ref.listenManual(routeTrackerProvider, (previous, next) {
      if (previous != null && previous != next && mounted) {
        _generation++;
        setState(() {
          _running = false;
          _located.clear();
          _unknown.clear();
          _selected = null;
          _error = context.appLocalizations.auditStale;
        });
      }
    });
  }

  @override
  void dispose() {
    _generation++;
    _spin?.cancel();
    super.dispose();
  }

  List<Proxy> _leafNodes() {
    final groups = ref.read(groupsProvider);
    final groupNames = {for (final group in groups) group.name};
    final seen = <String>{};
    return [
      for (final group in groups)
        for (final proxy in group.all)
          if (!groupNames.contains(proxy.name) &&
              !_builtinNames.contains(proxy.name) &&
              !_groupTypes.contains(proxy.type) &&
              seen.add(proxy.name))
            proxy,
    ];
  }

  Future<void> _start() async {
    if (_running) return;
    if (!ref.read(isStartProvider)) {
      setState(() => _error = context.appLocalizations.diagnosticsNeedCore);
      return;
    }
    final nodes = _leafNodes();
    final generation = ++_generation;
    final core = ref.read(coreHandlerProvider);
    var cursor = 0;
    setState(() {
      _running = true;
      _error = null;
      _located.clear();
      _unknown.clear();
      _selected = null;
      _probed = 0;
      _total = nodes.length;
    });
    Future<void> worker() async {
      while (mounted && generation == _generation && cursor < nodes.length) {
        final node = nodes[cursor++];
        NodeGeo? located;
        try {
          final result = await lookupOutboundIp(core, node.name);
          final info = parseOutboundIp(result);
          if (info != null) {
            final coordinates = await lookupCoordinates(request.dio, info.ip);
            if (coordinates != null) {
              located = NodeGeo(
                name: node.name,
                type: node.type,
                ip: info.ip,
                coordinates: coordinates,
              );
            }
          }
        } catch (_) {
          located = null;
        }
        if (!mounted || generation != _generation) return;
        setState(() {
          _probed++;
          if (located != null) {
            _located.add(located);
          } else {
            _unknown.add(node.name);
          }
        });
      }
    }

    try {
      await Future.wait(List.generate(4, (_) => worker()));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _running = false);
      }
    }
  }

  void _cancel() {
    _generation++;
    setState(() => _running = false);
  }

  void _selectCluster(GeoCluster cluster, {bool center = false}) {
    setState(() {
      _selected = cluster;
      if (center) {
        _yaw = -cluster.longitude;
        _pitch = (cluster.latitude * 0.7).clamp(-60, 60).toDouble();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final clusters = clusterNodeGeos(_located);
    final globe = _GlobeStage(
      flat: _flat,
      yaw: _yaw,
      pitch: _pitch,
      zoom: _zoom,
      clusters: clusters,
      selected: _selected,
      onSelect: (cluster) => _selectCluster(cluster),
      onGestureStart: () {
        _gestureYaw = _yaw;
        _gesturePitch = _pitch;
        _gestureZoom = _zoom;
      },
      onGestureUpdate: (delta, scale) {
        setState(() {
          _autoRotate = false;
          _yaw = _gestureYaw + delta.dx * 0.35;
          _pitch = (_gesturePitch - delta.dy * 0.35).clamp(-60, 60).toDouble();
          _zoom = (_gestureZoom * scale).clamp(0.7, 1.8).toDouble();
        });
      },
    );
    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _running ? _cancel : _start,
              icon: GlyphIcon(
                _running ? AppGlyphs.close : AppGlyphs.playPause(0),
                fill: 1,
              ),
              label: Text(_running ? l10n.cancel : l10n.start),
            ),
            ChoiceChip(
              label: Text(l10n.nodeGlobeSphere),
              selected: !_flat,
              onSelected: (_) => setState(() => _flat = false),
            ),
            ChoiceChip(
              label: Text(l10n.nodeGlobeFlat),
              selected: _flat,
              onSelected: (_) => setState(() => _flat = true),
            ),
            if (!_flat)
              ChoiceChip(
                label: Text(l10n.nodeGlobeAutoRotate),
                selected: _autoRotate,
                onSelected: (selected) =>
                    setState(() => _autoRotate = selected),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          _total == 0
              ? l10n.nodeGlobeNotRun
              : '$_probed / $_total · ${clusters.length} · ${_unknown.length} ${l10n.nodeGlobeUnknown}',
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: context.colorScheme.error),
            ),
          ),
        const SizedBox(height: 12),
        if (_selected != null)
          _ClusterDetail(
            cluster: _selected!,
            onClose: () => setState(() => _selected = null),
          )
        else
          _ClusterList(
            clusters: clusters,
            onSelect: (cluster) => _selectCluster(cluster, center: true),
          ),
        if (_unknown.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '${l10n.nodeGlobeUnknown} · ${_unknown.length}',
            style: AppTextStyle.subheadline.of(context, emphasized: true),
          ),
          const SizedBox(height: 6),
          for (final name in _unknown)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: context.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ],
    );
    return BaseScaffold(
      title: l10n.nodeGlobeTitle,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          if (!wide) {
            return ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                context.appBarInset + 12,
                16,
                24 + context.bottomInset,
              ),
              children: [globe, const SizedBox(height: 12), side],
            );
          }
          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              context.appBarInset + 12,
              16,
              16 + context.bottomInset,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: globe),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: SingleChildScrollView(child: side)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _GlobeStage extends StatelessWidget {
  const _GlobeStage({
    required this.flat,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.clusters,
    required this.selected,
    required this.onSelect,
    required this.onGestureStart,
    required this.onGestureUpdate,
  });

  final bool flat;
  final double yaw;
  final double pitch;
  final double zoom;
  final List<GeoCluster> clusters;
  final GeoCluster? selected;
  final void Function(GeoCluster) onSelect;
  final VoidCallback onGestureStart;
  final void Function(Offset delta, double scale) onGestureUpdate;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    Offset gestureOrigin = Offset.zero;
    return CommonCard(
      radius: 12,
      padding: const EdgeInsets.all(12),
      child: AspectRatio(
        aspectRatio: flat ? 2 : 1,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            return GestureDetector(
              onScaleStart: (details) {
                gestureOrigin = details.focalPoint;
                onGestureStart();
              },
              onScaleUpdate: (details) {
                onGestureUpdate(
                  details.focalPoint - gestureOrigin,
                  details.scale,
                );
              },
              onTapUp: (details) {
                final tap = details.localPosition;
                GeoCluster? best;
                var bestDistance = 30.0;
                for (final cluster in clusters) {
                  final point = flat
                      ? Offset(
                          (cluster.longitude + 180) / 360 * size.width,
                          (90 - cluster.latitude) / 180 * size.height,
                        )
                      : projectGlobe(
                          latitude: cluster.latitude,
                          longitude: cluster.longitude,
                          yawDegrees: yaw,
                          pitchDegrees: pitch,
                          size: size,
                          zoom: zoom,
                        )?.offset;
                  if (point == null) continue;
                  final distance = (point - tap).distance;
                  if (distance < bestDistance) {
                    bestDistance = distance;
                    best = cluster;
                  }
                }
                if (best != null) onSelect(best);
              },
              child: CustomPaint(
                size: size,
                painter: flat
                    ? _FlatPainter(
                        clusters: clusters,
                        selected: selected,
                        landColor: colorScheme.primary,
                        pointColor: colorScheme.primary,
                        selectedColor: colorScheme.error,
                        surface: colorScheme.surfaceContainerHigh,
                      )
                    : _GlobePainter(
                        countStyle: AppTextStyle.caption1.of(
                          context,
                          emphasized: true,
                        ),
                        yaw: yaw,
                        pitch: pitch,
                        zoom: zoom,
                        clusters: clusters,
                        selected: selected,
                        landColor: colorScheme.primary,
                        pointColor: colorScheme.primary,
                        selectedColor: colorScheme.error,
                        sphereLight: colorScheme.surfaceContainerHigh,
                        sphereDark: colorScheme.surfaceContainerLowest,
                        rimColor: colorScheme.outline,
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GlobePainter extends CustomPainter {
  const _GlobePainter({
    required this.countStyle,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.clusters,
    required this.selected,
    required this.landColor,
    required this.pointColor,
    required this.selectedColor,
    required this.sphereLight,
    required this.sphereDark,
    required this.rimColor,
  });

  final TextStyle countStyle;
  final double yaw;
  final double pitch;
  final double zoom;
  final List<GeoCluster> clusters;
  final GeoCluster? selected;
  final Color landColor;
  final Color pointColor;
  final Color selectedColor;
  final Color sphereLight;
  final Color sphereDark;
  final Color rimColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 * zoom;
    final sphere = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.4),
          radius: 1.1,
          colors: [sphereLight, sphereDark],
        ).createShader(sphere),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = rimColor.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.save();
    canvas.clipPath(Path()..addOval(sphere));

    // Graticule.
    final gridPaint = Paint()
      ..color = landColor.withValues(alpha: 0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var lon = -150; lon <= 180; lon += 30) {
      final path = Path();
      var started = false;
      for (var lat = -90; lat <= 90; lat += 5) {
        final point = projectGlobe(
          latitude: lat.toDouble(),
          longitude: lon.toDouble(),
          yawDegrees: yaw,
          pitchDegrees: pitch,
          size: size,
          zoom: zoom,
        );
        if (point == null) {
          started = false;
          continue;
        }
        if (!started) {
          path.moveTo(point.offset.dx, point.offset.dy);
          started = true;
        } else {
          path.lineTo(point.offset.dx, point.offset.dy);
        }
      }
      canvas.drawPath(path, gridPaint);
    }
    for (var lat = -60; lat <= 60; lat += 30) {
      final path = Path();
      var started = false;
      for (var lon = -180; lon <= 180; lon += 5) {
        final point = projectGlobe(
          latitude: lat.toDouble(),
          longitude: lon.toDouble(),
          yawDegrees: yaw,
          pitchDegrees: pitch,
          size: size,
          zoom: zoom,
        );
        if (point == null) {
          started = false;
          continue;
        }
        if (!started) {
          path.moveTo(point.offset.dx, point.offset.dy);
          started = true;
        } else {
          path.lineTo(point.offset.dx, point.offset.dy);
        }
      }
      canvas.drawPath(path, gridPaint);
    }

    // The dotted landmass.
    final dotPaint = Paint()..style = PaintingStyle.fill;
    for (var row = 0; row < landGridRows; row++) {
      for (var col = 0; col < landGridColumns; col++) {
        if (!isLandGridCell(col, row)) continue;
        final point = projectGlobe(
          latitude: 90 - (row + 0.5) * landGridStepDegrees,
          longitude: -180 + (col + 0.5) * landGridStepDegrees,
          yawDegrees: yaw,
          pitchDegrees: pitch,
          size: size,
          zoom: zoom,
        );
        if (point == null) continue;
        dotPaint.color = landColor.withValues(alpha: 0.18 + 0.5 * point.depth);
        canvas.drawCircle(point.offset, 0.9 + point.depth, dotPaint);
      }
    }

    // Node clusters.
    for (final cluster in clusters) {
      final point = projectGlobe(
        latitude: cluster.latitude,
        longitude: cluster.longitude,
        yawDegrees: yaw,
        pitchDegrees: pitch,
        size: size,
        zoom: zoom,
      );
      if (point == null) continue;
      final isSelected = cluster == selected;
      final dotRadius = (4 + math.min(cluster.nodes.length, 8)) * 1.0;
      canvas.drawCircle(
        point.offset,
        dotRadius + 4,
        Paint()
          ..color = (isSelected ? selectedColor : pointColor).withValues(
            alpha: 0.22,
          ),
      );
      canvas.drawCircle(
        point.offset,
        dotRadius,
        Paint()..color = isSelected ? selectedColor : pointColor,
      );
      if (cluster.nodes.length > 1) {
        final painter = TextPainter(
          text: TextSpan(
            text: '${cluster.nodes.length}',
            style: countStyle.copyWith(
              color: isSelected ? selectedColor : pointColor,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(
          canvas,
          point.offset + Offset(dotRadius + 2, -painter.height / 2),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlobePainter oldDelegate) =>
      yaw != oldDelegate.yaw ||
      pitch != oldDelegate.pitch ||
      zoom != oldDelegate.zoom ||
      clusters != oldDelegate.clusters ||
      selected != oldDelegate.selected;
}

class _FlatPainter extends CustomPainter {
  const _FlatPainter({
    required this.clusters,
    required this.selected,
    required this.landColor,
    required this.pointColor,
    required this.selectedColor,
    required this.surface,
  });

  final List<GeoCluster> clusters;
  final GeoCluster? selected;
  final Color landColor;
  final Color pointColor;
  final Color selectedColor;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = surface.withValues(alpha: 0.35),
    );
    final dotPaint = Paint()..color = landColor.withValues(alpha: 0.4);
    for (var row = 0; row < landGridRows; row++) {
      for (var col = 0; col < landGridColumns; col++) {
        if (!isLandGridCell(col, row)) continue;
        final lon = -180 + (col + 0.5) * landGridStepDegrees;
        final lat = 90 - (row + 0.5) * landGridStepDegrees;
        canvas.drawCircle(
          Offset(
            (lon + 180) / 360 * size.width,
            (90 - lat) / 180 * size.height,
          ),
          1.4,
          dotPaint,
        );
      }
    }
    for (final cluster in clusters) {
      final point = Offset(
        (cluster.longitude + 180) / 360 * size.width,
        (90 - cluster.latitude) / 180 * size.height,
      );
      final isSelected = cluster == selected;
      canvas.drawCircle(
        point,
        6,
        Paint()
          ..color = (isSelected ? selectedColor : pointColor).withValues(
            alpha: 0.25,
          ),
      );
      canvas.drawCircle(
        point,
        3.5,
        Paint()..color = isSelected ? selectedColor : pointColor,
      );
    }
  }

  @override
  bool shouldRepaint(_FlatPainter oldDelegate) =>
      clusters != oldDelegate.clusters || selected != oldDelegate.selected;
}

class _ClusterList extends StatelessWidget {
  const _ClusterList({required this.clusters, required this.onSelect});

  final List<GeoCluster> clusters;
  final void Function(GeoCluster) onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final cluster in clusters)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: CommonCard(
              radius: 12,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              onPressed: () => onSelect(cluster),
              child: Row(
                spacing: 10,
                children: [
                  FlagIcon(countryCode: cluster.countryCode, width: 26),
                  Expanded(
                    child: Text(
                      cluster.city.isEmpty
                          ? cluster.countryCode
                          : '${cluster.city} · ${cluster.countryCode}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.subheadline.of(
                        context,
                        emphasized: true,
                      ),
                    ),
                  ),
                  Text(
                    '${cluster.nodes.length}',
                    style: AppTextStyle.subheadline
                        .of(context, emphasized: true)
                        .toJetBrainsMono
                        .copyWith(color: context.colorScheme.primary),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ClusterDetail extends StatelessWidget {
  const _ClusterDetail({required this.cluster, required this.onClose});

  final GeoCluster cluster;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return CommonCard(
      radius: 12,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            spacing: 10,
            children: [
              FlagIcon(countryCode: cluster.countryCode, width: 28),
              Expanded(
                child: Text(
                  cluster.city.isEmpty
                      ? cluster.countryCode
                      : '${cluster.city} · ${cluster.countryCode} · ${cluster.nodes.length}',
                  style: AppTextStyle.subheadline.of(context, emphasized: true),
                ),
              ),
              IconButton(
                onPressed: onClose,
                tooltip: context.appLocalizations.close,
                icon: const GlyphIcon(AppGlyphs.close),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final node in cluster.nodes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.callout.of(context),
                    ),
                  ),
                  Text(
                    node.type,
                    style: AppTextStyle.caption1
                        .of(context)
                        .copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                  Text(
                    node.ip,
                    style: AppTextStyle.caption1
                        .of(context)
                        .toJetBrainsMono
                        .copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

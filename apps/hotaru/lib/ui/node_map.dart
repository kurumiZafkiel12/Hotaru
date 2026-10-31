import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import 'icons/icons.dart';
import 'node_globe.dart';
import 'shape.dart';
import 'typography.dart';

class NodeMap extends StatefulWidget {
  const NodeMap({
    super.key,
    required this.markers,
    required this.labels,
    required this.onSelected,
    required this.onAttribution,
    required this.unavailableLabel,
    required this.retryLabel,
    required this.zoomInLabel,
    required this.zoomOutLabel,
    this.focus,
    this.tileProvider,
  });

  final List<GlobeMarker> markers;
  final Map<String, String> labels;
  final ValueChanged<List<String>> onSelected;
  final VoidCallback onAttribution;
  final String unavailableLabel;
  final String retryLabel;
  final String zoomInLabel;
  final String zoomOutLabel;
  final GlobeFocus? focus;
  final TileProvider? tileProvider;

  @override
  State<NodeMap> createState() => _NodeMapState();
}

class _NodeMapState extends State<NodeMap> {
  final _controller = MapController();
  late TileProvider _tiles;
  bool _ready = false;
  bool _failed = false;
  int _revision = 0;
  bool _failureQueued = false;

  TileProvider _newTiles() =>
      widget.tileProvider ??
      NetworkTileProvider(
        headers: const {
          'User-Agent': 'Hotaru (+https://github.com/kurumiZafkiel12/Hotaru)',
        },
        cachingProvider: BuiltInMapCachingProvider.getOrCreateInstance(
          maxCacheSize: 64 * 1024 * 1024,
        ),
        silenceExceptions: true,
      );

  @override
  void initState() {
    super.initState();
    _tiles = _newTiles();
  }

  void _position() {
    if (!_ready) return;
    final focus = widget.focus;
    if (focus != null) {
      _controller.move(
        LatLng(focus.latitude.clamp(-85, 85), focus.longitude),
        math.max(8, _controller.camera.zoom),
      );
    } else if (widget.markers.isNotEmpty) {
      _controller.fitCamera(
        CameraFit.coordinates(
          coordinates: [
            for (final marker in widget.markers)
              LatLng(marker.latitude.clamp(-85, 85), marker.longitude),
          ],
          padding: const EdgeInsets.all(44),
          maxZoom: 10,
        ),
      );
    }
  }

  @override
  void didUpdateWidget(NodeMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focus != widget.focus ||
        (oldWidget.markers.isEmpty && widget.markers.isNotEmpty)) {
      _position();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _zoom(double change) {
    _controller.move(
      _controller.camera.center,
      (_controller.camera.zoom + change).clamp(1, 19),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final revision = _revision;
    final grouped = <(double, double), List<GlobeMarker>>{};
    for (final marker in widget.markers) {
      (grouped[(marker.latitude, marker.longitude)] ??= []).add(marker);
    }
    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: const LatLng(15, 0),
            initialZoom: 2,
            minZoom: 1,
            maxZoom: 19,
            backgroundColor: colors.surface,
            onMapReady: () {
              _ready = true;
              _position();
            },
          ),
          children: [
            TileLayer(
              key: ValueKey(_revision),
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              tileProvider: _tiles,
              userAgentPackageName: 'dev.hotaru.hotaru',
              maxNativeZoom: 19,
              keepBuffer: 1,
              errorTileCallback: (_, _, _) {
                if (!mounted ||
                    _failed ||
                    _failureQueued ||
                    revision != _revision) {
                  return;
                }
                _failureQueued = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _failureQueued = false;
                  if (mounted && revision == _revision) {
                    setState(() => _failed = true);
                  }
                });
              },
            ),
            MarkerLayer(
              markers: [
                for (final entry in grouped.entries)
                  Marker(
                    key: ValueKey('node-map-${entry.value.first.id}'),
                    point: LatLng(entry.key.$1.clamp(-85, 85), entry.key.$2),
                    width: 144,
                    height: 40,
                    child: Tooltip(
                      message: entry.value
                          .map(
                            (marker) =>
                                '${marker.id} · ${widget.labels[marker.id] ?? ''}',
                          )
                          .join('\n'),
                      child: Material(
                        color: colors.primary,
                        shape: AppShape.sm,
                        child: InkWell(
                          customBorder: AppShape.sm,
                          onTap: () => widget.onSelected([
                            for (final marker in entry.value) marker.id,
                          ]),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(
                              spacing: 4,
                              children: [
                                GlyphIcon(
                                  AppGlyphs.pin,
                                  size: 16,
                                  color: colors.onPrimary,
                                ),
                                Expanded(
                                  child: Text(
                                    entry.value.length > 1
                                        ? '${entry.value.length} IP'
                                        : widget.labels[entry.value.first.id] ??
                                              entry.value.first.id,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyle.caption1
                                        .of(context)
                                        .copyWith(color: colors.onPrimary),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        Positioned(
          top: 8,
          right: 8,
          child: Material(
            color: colors.surfaceContainer,
            shape: AppShape.sm,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: widget.zoomInLabel,
                  onPressed: () => _zoom(1),
                  icon: const GlyphIcon(AppGlyphs.add),
                ),
                IconButton(
                  tooltip: widget.zoomOutLabel,
                  onPressed: () => _zoom(-1),
                  icon: const GlyphIcon(AppGlyphs.remove),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          right: 0,
          child: Material(
            color: colors.surface,
            child: TextButton(
              onPressed: widget.onAttribution,
              child: const Text('© OpenStreetMap contributors'),
            ),
          ),
        ),
        if (_failed)
          Positioned(
            left: 8,
            right: 8,
            bottom: 44,
            child: Material(
              color: colors.surfaceContainer,
              shape: AppShape.sm,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.unavailableLabel,
                        style: AppTextStyle.caption1.of(context),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _failed = false;
                        _revision++;
                        _tiles = _newTiles();
                      }),
                      child: Text(widget.retryLabel),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

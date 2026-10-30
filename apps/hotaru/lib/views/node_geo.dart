import 'dart:async';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/country_names.dart';
import 'package:hotaru/common/node_geo.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/node_geo.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/ui/node_globe.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class NodeGeoView extends ConsumerStatefulWidget {
  const NodeGeoView({super.key});
  @override
  ConsumerState<NodeGeoView> createState() => _NodeGeoViewState();
}

class _NodeGeoViewState extends ConsumerState<NodeGeoView> {
  List<NodeGeoTarget> _nodes = const [];
  final _observations = <String, NodeGeoObservation>{};
  NodeGeoRunner? _runner;
  late final RouteTracker _routeTracker;
  GlobeFocus? _focus;
  Set<String>? _cluster;
  String? _selected;
  String _query = '';
  String? _error;
  bool _loading = false;
  bool _running = false;
  bool _flat = false;
  bool _initialized = false;
  int _generation = 0;
  int _finished = 0;
  int _total = 0;

  String get _routeKey {
    final route = ref.read(routeTrackerProvider);
    return '${route.coreEpoch}/${route.routeVersion}/${route.hostEpoch}/${route.proxied}';
  }

  @override
  void initState() {
    super.initState();
    _routeTracker = ref.read(routeTrackerProvider.notifier);
    _routeTracker.attach();
    ref.listenManual(routeTrackerProvider, (before, after) {
      if (before != null && before != after && mounted) {
        _cancel();
        unawaited(_load());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      unawaited(_load());
    }
  }

  void _cancel({bool notify = true}) {
    _generation++;
    _runner?.cancel();
    _runner = null;
    if (notify && mounted) {
      setState(() {
        _running = false;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _cancel(notify: false);
    _routeTracker.detach();
    super.dispose();
  }

  Future<void> _load() async {
    if (_running) return;
    if (!ref.read(isStartProvider)) {
      if (mounted) {
        setState(() => _error = context.appLocalizations.diagnosticsNeedCore);
      }
      return;
    }
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(coreHandlerProvider).getProxies();
      final nodes = await compute(NodeGeoTarget.fromProxies, data);
      if (!mounted || generation != _generation) return;
      setState(() {
        _nodes = nodes;
        _cluster = null;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = context.appLocalizations.diagnosticsFailed);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _start({NodeGeoTarget? only}) async {
    if (_running || _loading) return;
    if (!ref.read(isStartProvider)) {
      setState(() => _error = context.appLocalizations.diagnosticsNeedCore);
      return;
    }
    final nodes = only == null ? _nodes : [only];
    if (nodes.isEmpty) {
      await _load();
      return;
    }
    final generation = ++_generation;
    final key = _routeKey;
    final route = ref.read(routeTrackerProvider);
    final core = ref.read(coreHandlerProvider);
    final runner = _runner = NodeGeoRunner(
      cache: ref.read(nodeGeoCacheProvider),
      routeKey: key,
      coreEpoch: route.coreEpoch,
      routeVersion: route.routeVersion,
      probe: (name) => core.outboundIp(
        OutboundIpParams(
          proxyName: name,
          urls: const [nodeGeoSource],
          timeout: 8000,
        ),
      ),
    );
    setState(() {
      _running = true;
      _error = null;
      _finished = 0;
      _total = nodes.length;
    });
    try {
      await runner.run(
        nodes,
        force: only != null,
        onResult: (result) {
          if (mounted && generation == _generation && key == _routeKey) {
            setState(() {
              _observations[result.target.name] = result;
              _finished++;
            });
          }
        },
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _running = false;
          _runner = null;
        });
      }
    }
  }

  void _select(NodeGeoObservation item) {
    final location = item.location;
    if (location == null || item.routeKey != _routeKey) return;
    setState(() {
      _selected = item.target.name;
      _focus = GlobeFocus(location.latitude, location.longitude);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final routeKey = _routeKey;
    bool matches(NodeGeoTarget node) {
      final location = _observations[node.name]?.location;
      final text =
          '${node.name} ${node.server} ${location?.ip ?? ''} ${location?.country ?? ''} ${location?.city ?? ''}'
              .toLowerCase();
      return text.contains(_query.toLowerCase()) &&
          (_cluster == null || _cluster!.contains(node.name));
    }

    final shown = _nodes.where(matches).toList();
    final markers = [
      for (final node in shown)
        if (_observations[node.name] case final result?)
          if (result.routeKey == routeKey)
            if (result.location case final location?)
              GlobeMarker(
                id: node.name,
                latitude: location.latitude,
                longitude: location.longitude,
              ),
    ];
    return CommonScaffold(
      title: l10n.nodeGlobeTitle,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: l10n.latencyDiagnosticsRefresh,
          isLoading: _loading,
          onPressed: _running ? null : _load,
        ),
      ],
      body: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          context.appBarInset,
          12,
          12 + context.bottomInset,
        ),
        child: Column(
          spacing: 10,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.nodeGeoScope, style: AppTextStyle.footnote.of(context)),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: _loading
                      ? null
                      : _running
                      ? _cancel
                      : _start,
                  child: Text(_running ? l10n.cancel : l10n.nodeGeoCheckAll),
                ),
                Text(
                  '$_finished / $_total',
                  style: AppTextStyle.footnote.of(context).toTabular,
                ),
                ChoiceChip(
                  label: const Text('3D'),
                  selected: !_flat,
                  onSelected: (_) => setState(() => _flat = false),
                ),
                ChoiceChip(
                  label: const Text('2D'),
                  selected: _flat,
                  onSelected: (_) => setState(() => _flat = true),
                ),
                if (_cluster != null)
                  TextButton(
                    onPressed: () => setState(() => _cluster = null),
                    child: Text(l10n.selectAll),
                  ),
              ],
            ),
            TextField(
              decoration: InputDecoration(
                hintText: l10n.nodeGeoSearch,
                prefixIcon: const GlyphIcon(AppGlyphs.search),
              ),
              onChanged: (value) => setState(() {
                _query = value;
                _cluster = null;
              }),
              onSubmitted: (_) {
                if (shown.isNotEmpty) {
                  final item = _observations[shown.first.name];
                  if (item != null) _select(item);
                }
              },
            ),
            if (_error != null)
              Text(
                _error!,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: context.colorScheme.error),
              ),
            if (_running)
              LinearProgressIndicator(
                value: _total == 0 ? null : _finished / _total,
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final globe = ClipRSuperellipse(
                    borderRadius: AppRadius.lg,
                    child: NodeGlobe(
                      markers: markers,
                      focus: _focus,
                      flat: _flat,
                      label: l10n.nodeGlobeTitle,
                      onSelected: (ids) {
                        setState(() => _cluster = ids.toSet());
                        if (ids.length == 1) {
                          final item = _observations[ids.single];
                          if (item != null) _select(item);
                        }
                      },
                    ),
                  );
                  final list = shown.isEmpty
                      ? Center(
                          child: Text(
                            _loading ? l10n.loading : l10n.nodeGeoEmpty,
                          ),
                        )
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (context, index) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _nodeRow(shown[index], routeKey),
                          ),
                        );
                  return Theme.of(context).platform != TargetPlatform.android &&
                          constraints.maxWidth >= 720
                      ? Row(
                          spacing: 12,
                          children: [
                            Expanded(flex: 3, child: globe),
                            Expanded(flex: 2, child: list),
                          ],
                        )
                      : Column(
                          spacing: 10,
                          children: [
                            SizedBox(
                              height: (constraints.maxHeight * 0.45).clamp(
                                0,
                                260,
                              ),
                              width: double.infinity,
                              child: globe,
                            ),
                            Expanded(child: list),
                          ],
                        );
                },
              ),
            ),
            Text(
              l10n.nodeGeoEstimate,
              style: AppTextStyle.caption2.of(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nodeRow(NodeGeoTarget node, String routeKey) {
    final item = _observations[node.name];
    final location = item?.location;
    final l10n = context.appLocalizations;
    final fresh = item?.routeKey == routeKey;
    final status = item == null
        ? l10n.servicePending
        : !fresh
        ? l10n.auditStale
        : location == null
        ? l10n.diagnosticsFailed
        : '${location.country} ${countryName(location.country, Localizations.localeOf(context).languageCode) ?? location.country} · ${location.city}';
    return CommonCard(
      padding: const EdgeInsets.all(12),
      onPressed: item == null ? null : () => _select(item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: node.name,
                  child: Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.subheadline.of(
                      context,
                      emphasized: true,
                    ),
                  ),
                ),
              ),
              if (_selected == node.name) const SelectionCheck(),
              IconButton(
                tooltip: l10n.retry,
                onPressed: _running || _loading
                    ? null
                    : () => _start(only: node),
                icon: const GlyphIcon(AppGlyphs.refresh, size: 18),
              ),
            ],
          ),
          Row(
            spacing: 6,
            children: [
              if (location != null && location.country.isNotEmpty)
                Text(
                  location.country.countryFlagEmoji,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(fontFamily: FontFamily.twEmoji.value),
                ),
              Expanded(
                child: Text(status, style: AppTextStyle.footnote.of(context)),
              ),
            ],
          ),
          if (location != null)
            Text(
              '${l10n.outboundIp}: ${location.ip}',
              style: AppTextStyle.footnote.of(context).toJetBrainsMono,
            ),
          ExpansionTile(
            title: Text(
              l10n.nodeGeoDetails,
              style: AppTextStyle.caption1.of(context),
            ),
            shape: AppShape.lg,
            collapsedShape: AppShape.lg,
            children: [
              SelectableText(
                '${l10n.nodeGeoEntry}: ${node.server.isEmpty ? l10n.unknown : node.server}\n${item?.entryAddresses.isNotEmpty == true ? item!.entryAddresses.join(', ') : l10n.unknown}\n${l10n.nodeGeoSource}: GeoJS\n${item?.checkedAt.toLocal().toIso8601String() ?? '—'}\n${location?.organization ?? ''} · AS${location?.asn ?? '—'}\n${item?.chains.join(' ➜ ') ?? ''}\n${item?.error ?? ''}',
                style: AppTextStyle.caption1.of(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

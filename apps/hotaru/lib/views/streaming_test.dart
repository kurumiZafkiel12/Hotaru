import 'dart:async';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/ui/ui.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'service_audit.dart' show serviceAuditStatus;

/// Which summary bucket a verdict falls into on this page: a service
/// is unlocked, not unlocked, or the evidence says something else.
enum _Bucket { unlocked, notUnlocked, other }

_Bucket _bucketOf(ServiceProbeStatus status) => switch (status) {
  ServiceProbeStatus.available ||
  ServiceProbeStatus.originalsOnly => _Bucket.unlocked,
  ServiceProbeStatus.unavailable ||
  ServiceProbeStatus.unsupportedRegion ||
  ServiceProbeStatus.blocked ||
  ServiceProbeStatus.disallowedIsp => _Bucket.notUnlocked,
  _ => _Bucket.other,
};

/// The unlock test: every catalog service judged one by one, with the
/// verdict up front and the latency small underneath — the audit page
/// keeps the route evidence; this page is for the answer.
class StreamingTestView extends ConsumerStatefulWidget {
  const StreamingTestView({super.key});

  @override
  ConsumerState<StreamingTestView> createState() => _StreamingTestViewState();
}

class _StreamingTestViewState extends ConsumerState<StreamingTestView> {
  final _results = <ServiceTarget, ServiceCheck>{};
  final _stale = <ServiceTarget>{};
  final _pending = <ServiceTarget>{};
  int _generation = 0;
  String? _runId;
  String? _category;
  bool _lockedOnly = false;
  String? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(routeTrackerProvider, (previous, next) {
      if (previous != null && previous != next && mounted) {
        _cancel();
        setState(() => _stale.addAll(_results.keys));
      }
    });
  }

  void _cancel({bool notify = true}) {
    _generation++;
    final id = _runId;
    _runId = null;
    if (id != null) {
      unawaited(
        ref
            .read(coreHandlerProvider)
            .serviceCheck(
              ServiceCheckParams(timeout: 1000, runId: id, cancel: true),
            )
            .catchError((Object _) => <ServiceCheckItem>[]),
      );
    }
    if (mounted && notify) {
      setState(() {
        _running = false;
        _pending.clear();
      });
    }
  }

  @override
  void dispose() {
    _cancel(notify: false);
    super.dispose();
  }

  Future<void> _start({ServiceTarget? only}) async {
    if (_running) return;
    if (!ref.read(isStartProvider)) {
      setState(() => _error = context.appLocalizations.diagnosticsNeedCore);
      return;
    }
    final generation = ++_generation;
    final id = 'streaming-${DateTime.now().microsecondsSinceEpoch}';
    final core = ref.read(coreHandlerProvider);
    final targets = only == null
        ? ServiceTarget.values
              .where(
                (target) => _category == null || target.category == _category,
              )
              .toList()
        : [only];
    var cursor = 0;
    setState(() {
      _runId = id;
      _running = true;
      _error = null;
      for (final target in targets) {
        _results.remove(target);
        _stale.remove(target);
      }
    });
    Future<void> worker() async {
      while (mounted && generation == _generation && cursor < targets.length) {
        final target = targets[cursor++];
        setState(() => _pending.add(target));
        try {
          final items = await core.serviceCheck(
            ServiceCheckParams(names: [target.id], timeout: 8000, runId: id),
          );
          if (!mounted || generation != _generation) return;
          final item = items.firstOrNull;
          setState(() {
            _results[target] = item == null
                ? const ServiceCheck(ServiceProbeStatus.failed)
                : ServiceCheck.of(item);
            _pending.remove(target);
          });
        } catch (error) {
          if (!mounted || generation != _generation) return;
          setState(() {
            _results[target] = const ServiceCheck(ServiceProbeStatus.failed);
            _pending.remove(target);
            _error = compactError(error);
          });
        }
      }
    }

    try {
      await Future.wait(List.generate(4, (_) => worker()));
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _running = false;
          _pending.clear();
          _runId = null;
        });
      }
    }
  }

  String _categoryLabel(String category) {
    final l10n = context.appLocalizations;
    return switch (category) {
      'ai' => l10n.auditAI,
      'media' => l10n.auditMedia,
      'domestic' => l10n.auditDomestic,
      'social' => l10n.auditSocial,
      'developer' => l10n.auditDeveloper,
      _ => l10n.auditGames,
    };
  }

  bool _visible(ServiceTarget target) {
    if (_category != null && target.category != _category) return false;
    if (_lockedOnly) {
      final check = _results[target];
      return check != null &&
          !_stale.contains(target) &&
          _bucketOf(check.status) == _Bucket.notUnlocked;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    var unlocked = 0;
    var notUnlocked = 0;
    var other = 0;
    for (final entry in _results.entries) {
      if (_stale.contains(entry.key)) continue;
      switch (_bucketOf(entry.value.status)) {
        case _Bucket.unlocked:
          unlocked++;
        case _Bucket.notUnlocked:
          notUnlocked++;
        case _Bucket.other:
          other++;
      }
    }
    final visible = ServiceTarget.values.where(_visible).toList();
    final groups = <(_Bucket?, List<ServiceTarget>)>[
      if (_results.isEmpty)
        (null, visible)
      else ...[
        for (final bucket in _Bucket.values)
          (
            bucket,
            visible
                .where(
                  (target) =>
                      _results[target] != null &&
                      _bucketOf(_results[target]!.status) == bucket,
                )
                .toList(),
          ),
        (null, visible.where((target) => _results[target] == null).toList()),
      ],
    ];
    return BaseScaffold(
      title: l10n.streamingTestTitle,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.appBarInset + 12,
          16,
          24 + context.bottomInset,
        ),
        children: [
          CommonCard(
            radius: 12,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                for (final (value, label, color) in [
                  (
                    unlocked,
                    l10n.streamingUnlocked,
                    context.colorScheme.success,
                  ),
                  (
                    notUnlocked,
                    l10n.streamingNotUnlocked,
                    context.colorScheme.error,
                  ),
                  (other, l10n.streamingOther, context.colorScheme.warning),
                ])
                  Expanded(
                    child: Column(
                      spacing: 4,
                      children: [
                        Text(
                          '$value',
                          style: AppTextStyle.title2
                              .of(context, emphasized: true)
                              .toJetBrainsMono
                              .copyWith(color: color),
                        ),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          style: AppTextStyle.caption1.of(context),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(l10n.selectAll),
                selected: _category == null,
                onSelected: _running
                    ? null
                    : (_) => setState(() => _category = null),
              ),
              for (final category in const [
                'ai',
                'media',
                'domestic',
                'social',
                'developer',
                'games',
              ])
                ChoiceChip(
                  label: Text(_categoryLabel(category)),
                  selected: _category == category,
                  onSelected: _running
                      ? null
                      : (_) => setState(() => _category = category),
                ),
              ChoiceChip(
                label: Text(l10n.streamingLockedOnly),
                selected: _lockedOnly,
                onSelected: _running
                    ? null
                    : (selected) => setState(() => _lockedOnly = selected),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _running ? _cancel : _start,
                icon: GlyphIcon(
                  _running ? AppGlyphs.close : AppGlyphs.playPause(0),
                  fill: 1,
                ),
                label: Text(_running ? l10n.cancel : l10n.start),
              ),
              Text(
                '${_results.length} / ${ServiceTarget.values.length}',
                style: AppTextStyle.footnote.of(context).toTabular,
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: context.colorScheme.error),
              ),
            ),
          for (final (bucket, targets) in groups)
            if (targets.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Text(
                  bucket == null
                      ? l10n.selectAll
                      : '${switch (bucket) {
                          _Bucket.unlocked => l10n.streamingUnlocked,
                          _Bucket.notUnlocked => l10n.streamingNotUnlocked,
                          _Bucket.other => l10n.streamingOther,
                        }} · ${targets.length}',
                  style: AppTextStyle.subheadline.of(context, emphasized: true),
                ),
              ),
              for (final target in targets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _StreamingRow(
                    key: ValueKey(target),
                    target: target,
                    check: _results[target],
                    pending: _pending.contains(target),
                    stale: _stale.contains(target),
                    onRetry: _running ? null : () => _start(only: target),
                  ),
                ),
            ],
        ],
      ),
    );
  }
}

class _StreamingRow extends StatelessWidget {
  const _StreamingRow({
    super.key,
    required this.target,
    this.check,
    required this.pending,
    required this.stale,
    required this.onRetry,
  });

  final ServiceTarget target;
  final ServiceCheck? check;
  final bool pending;
  final bool stale;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final check = this.check;
    final bucket = check == null || stale ? null : _bucketOf(check.status);
    final region = check?.region;
    final showFlag = region != null && region.length == 2;
    return CommonCard(
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        spacing: 12,
        children: [
          SizedBox.square(
            dimension: 32,
            child: target.icon.isEmpty
                ? Center(
                    child: Text(
                      target.label.substring(0, 1),
                      style: AppTextStyle.title3
                          .of(context, emphasized: true)
                          .copyWith(color: colorScheme.primary),
                    ),
                  )
                : SvgPicture.asset(
                    'assets/images/services/${target.icon}.svg',
                    theme: SvgTheme(currentColor: colorScheme.primary),
                  ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  target.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.callout.of(context, emphasized: true),
                ),
                Row(
                  spacing: 5,
                  children: [
                    if (showFlag) FlagIcon(countryCode: region, width: 16),
                    Flexible(
                      child: Text(
                        [
                          if (region != null && region.isNotEmpty) region,
                          if (check?.delay != null) '${check!.delay} ms',
                          if (pending) l10n.loading,
                          if (stale) l10n.auditStale,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(
                              color: stale
                                  ? colorScheme.warning
                                  : colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (check != null && !pending)
            DecoratedBox(
              decoration: ShapeDecoration(
                color: switch (bucket) {
                  _Bucket.unlocked => colorScheme.success.withValues(
                    alpha: 0.16,
                  ),
                  _Bucket.notUnlocked => colorScheme.error.withValues(
                    alpha: 0.16,
                  ),
                  _ => colorScheme.surfaceContainerHigh,
                },
                shape: AppShape.full,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Text(
                  stale
                      ? l10n.auditStale
                      : serviceAuditStatus(context, check.status),
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(
                        color: switch (bucket) {
                          _Bucket.unlocked => colorScheme.success,
                          _Bucket.notUnlocked => colorScheme.error,
                          _ => colorScheme.onSurfaceVariant,
                        },
                      ),
                ),
              ),
            ),
          IconButton(
            tooltip: l10n.retry,
            onPressed: onRetry,
            icon: const GlyphIcon(AppGlyphs.refresh),
          ),
        ],
      ),
    );
  }
}

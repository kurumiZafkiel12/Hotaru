import 'dart:async';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

String serviceAuditStatus(BuildContext context, ServiceProbeStatus status) {
  final l10n = context.appLocalizations;
  return switch (status) {
    ServiceProbeStatus.available => l10n.auditUnlocked,
    ServiceProbeStatus.originalsOnly => l10n.serviceOriginalsOnly,
    ServiceProbeStatus.unsupportedRegion => l10n.serviceUnsupportedRegion,
    ServiceProbeStatus.disallowedIsp => l10n.serviceDisallowedIsp,
    ServiceProbeStatus.blocked => l10n.serviceBlocked,
    ServiceProbeStatus.restricted => l10n.serviceRestricted,
    ServiceProbeStatus.unavailable => l10n.serviceUnavailable,
    ServiceProbeStatus.comingSoon => l10n.serviceComingSoon,
    ServiceProbeStatus.timeout => l10n.timeout,
    ServiceProbeStatus.failed => l10n.serviceFailed,
    ServiceProbeStatus.reachable => l10n.auditUnlocked,
    ServiceProbeStatus.authenticationRequired => l10n.auditAuthentication,
    ServiceProbeStatus.challenge => l10n.auditChallenge,
    ServiceProbeStatus.inconclusive => l10n.auditInconclusive,
  };
}

class ServiceAuditView extends ConsumerStatefulWidget {
  const ServiceAuditView({super.key});

  @override
  ConsumerState<ServiceAuditView> createState() => _ServiceAuditViewState();
}

class _ServiceAuditViewState extends ConsumerState<ServiceAuditView> {
  final _results = <ServiceTarget, ServiceCheck>{};
  final _stale = <ServiceTarget>{};
  final _pending = <ServiceTarget>{};
  int _generation = 0;
  String? _runId;
  String? _category;
  ServiceOutcome? _outcome;
  int _completed = 0;
  int _total = 0;
  late final RouteTracker _routeTracker;
  String? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _routeTracker = ref.read(routeTrackerProvider.notifier);
    _routeTracker.attach();
    ref.listenManual(routeTrackerProvider, (previous, next) {
      if (previous != null &&
          next.invalidatesDiagnostics(previous) &&
          mounted) {
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
    _routeTracker.detach();
    super.dispose();
  }

  Future<void> _start({ServiceTarget? only}) async {
    if (_running) return;
    if (!ref.read(isStartProvider)) {
      setState(() => _error = context.appLocalizations.diagnosticsNeedCore);
      return;
    }
    final generation = ++_generation;
    final id = 'audit-${DateTime.now().microsecondsSinceEpoch}';
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
      _completed = 0;
      _total = targets.length;
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
          final check = item == null
              ? const ServiceCheck(ServiceProbeStatus.failed)
              : ServiceCheck.of(item);
          final held = check.hits.isEmpty
              ? null
              : await core.checkRoutes(CheckRoutesParams(routes: [check.hits]));
          if (!mounted || generation != _generation) return;
          setState(() {
            _results[target] = check;
            _completed++;
            _pending.remove(target);
            if (check.hits.isNotEmpty &&
                (held == null ||
                    held.held.firstOrNull != true ||
                    held.coreEpoch != check.coreEpoch)) {
              _stale.add(target);
            }
          });
        } catch (error) {
          if (!mounted || generation != _generation) return;
          setState(() {
            _results[target] = const ServiceCheck(ServiceProbeStatus.failed);
            _completed++;
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

  Widget _filters(List<Widget> children) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth < 600
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(spacing: 6, children: children),
          )
        : Wrap(spacing: 6, runSpacing: 6, children: children),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final results = _results.entries.where(
      (entry) => _category == null || entry.key.category == _category,
    );
    final counts = <ServiceOutcome, int>{};
    for (final entry in results) {
      final outcome = _stale.contains(entry.key)
          ? ServiceOutcome.unknown
          : entry.value.status.outcome;
      counts.update(outcome, (count) => count + 1, ifAbsent: () => 1);
    }
    final shown = ServiceTarget.values.where((target) {
      if (_category != null && target.category != _category) return false;
      if (_outcome == null) return true;
      final result = _results[target];
      if (result == null) return false;
      return (_stale.contains(target)
              ? ServiceOutcome.unknown
              : result.status.outcome) ==
          _outcome;
    }).toList();
    return BaseScaffold(
      title: l10n.auditTitle,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(
              16,
              context.appBarInset,
              16,
              24 + context.bottomInset,
            ),
            itemCount: shown.length + 1,
            itemBuilder: (context, index) {
              if (index > 0) {
                final target = shown[index - 1];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ServiceResult(
                    key: ValueKey(target),
                    target: target,
                    check: _results[target],
                    pending: _pending.contains(target),
                    stale: _stale.contains(target),
                    onRetry: _running ? null : () => _start(only: target),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.auditScope,
                    style: AppTextStyle.footnote.of(context),
                  ),
                  const SizedBox(height: 12),
                  CommonCard(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      spacing: 8,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.auditResultFilter,
                          style: AppTextStyle.footnote.of(
                            context,
                            emphasized: true,
                          ),
                        ),
                        _filters([
                          ChoiceChip(
                            label: Text(l10n.selectAll),
                            selected: _outcome == null,
                            onSelected: (_) => setState(() => _outcome = null),
                          ),
                          for (final outcome in ServiceOutcome.values)
                            ChoiceChip(
                              label: Text(
                                '${outcome.label} ${counts[outcome] ?? 0}',
                              ),
                              selected: _outcome == outcome,
                              onSelected: (selected) => setState(
                                () => _outcome = selected ? outcome : null,
                              ),
                            ),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _filters([
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
                  ]),
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
                        '$_completed / $_total',
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
                  const SizedBox(height: 12),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ServiceResult extends StatelessWidget {
  const _ServiceResult({
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
    final check = this.check;
    final observations = check?.observations ?? const <ServiceObservation>[];
    final hintStyle = AppTextStyle.footnote
        .of(context)
        .copyWith(color: context.colorScheme.onSurfaceVariant);
    final status = pending
        ? l10n.loading
        : stale
        ? l10n.auditStale
        : check == null
        ? '—'
        : check.status.outcome.label;
    final mismatch =
        target.expectsDirect &&
        observations.any(
          (observation) =>
              observation.chains.isNotEmpty &&
              observation.chains.first != directOutbound,
        );
    return CommonCard(
      child: ExpansionTile(
        leading: SizedBox.square(
          dimension: 32,
          child: target.icon.isEmpty
              ? Center(
                  child: Text(
                    target.label.substring(0, 1),
                    style: AppTextStyle.title3
                        .of(context, emphasized: true)
                        .copyWith(color: context.colorScheme.primary),
                  ),
                )
              : SvgPicture.asset(
                  'assets/images/services/${target.icon}.svg',
                  theme: SvgTheme(currentColor: context.colorScheme.primary),
                ),
        ),
        trailing: IconButton(
          tooltip: l10n.retry,
          onPressed: onRetry,
          icon: const GlyphIcon(AppGlyphs.refresh),
        ),
        title: Text(
          target.label,
          style: AppTextStyle.callout.of(context, emphasized: true),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text(
              status,
              style: AppTextStyle.subheadline
                  .of(context, emphasized: true)
                  .copyWith(
                    color: stale
                        ? context.colorScheme.warning
                        : check == null
                        ? context.colorScheme.onSurface
                        : switch (check.status.outcome) {
                            ServiceOutcome.unlocked =>
                              context.colorScheme.success,
                            ServiceOutcome.partial ||
                            ServiceOutcome.verification =>
                              context.colorScheme.warning,
                            ServiceOutcome.locked ||
                            ServiceOutcome.unsupported ||
                            ServiceOutcome.failed => context.colorScheme.error,
                            ServiceOutcome.unknown =>
                              context.colorScheme.onSurfaceVariant,
                          },
                  ),
            ),
            EmojiText(
              [
                if (check?.region != null)
                  '${check!.region!.countryFlagEmoji} ${check.region}',
                if (check?.delay != null) '${check!.delay} ms',
              ].join(' · '),
              style: AppTextStyle.caption2
                  .of(context)
                  .copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedAlignment: Alignment.centerLeft,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (check != null)
            Text(serviceAuditStatus(context, check.status), style: hintStyle),
          if (check?.status == ServiceProbeStatus.reachable)
            Text(l10n.auditEndpointPassScope, style: hintStyle),
          if (check?.status == ServiceProbeStatus.originalsOnly)
            Text(l10n.auditCatalogPartialEvidence, style: hintStyle),
          if (target.expectsDirect)
            Text(
              mismatch ? l10n.auditDirectMismatch : l10n.auditDirectExpected,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(
                    color: mismatch ? context.colorScheme.warning : null,
                  ),
            ),
          if (target == ServiceTarget.claude ||
              target == ServiceTarget.claudeApi)
            Text(l10n.auditClaudeHint, style: hintStyle),
          if (target == ServiceTarget.telegram)
            Text(l10n.auditTelegramHint, style: hintStyle),
          if (target.category == 'media' || target.category == 'domestic')
            Text(l10n.auditMediaHint, style: hintStyle),
          if (observations.isEmpty)
            Text(l10n.auditRouteMissing, style: hintStyle),
          for (final observation in observations)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(
                      observation.url,
                      style: AppTextStyle.caption1.of(context).toJetBrainsMono,
                    ),
                    Text(
                      observation.url.startsWith('mtproto:')
                          ? 'MTProto · ${observation.error.isEmpty ? l10n.auditReachable : observation.error}'
                          : 'HTTP ${observation.statusCode == 0 ? "—" : observation.statusCode}${observation.error.isEmpty ? "" : " · ${observation.error}"}',
                      style: AppTextStyle.footnote.of(context),
                    ),
                    Text(
                      '${observation.rule.isEmpty ? l10n.auditRuleUnknown : "${observation.rule}, ${observation.rulePayload}"} ➜ ${observation.chains.isEmpty ? l10n.auditRouteMissing : observation.chains.reversed.join(" ➜ ")}',
                      style: AppTextStyle.footnote.of(context).toJetBrainsMono,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

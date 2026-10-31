import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/dns_leak.dart';
import 'package:hotaru/common/country_names.dart';
import 'package:hotaru/common/ip_portrait.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'network_diagnostics.dart';

typedef PortraitDnsProbe =
    Future<List<DnsResolverReceipt>> Function(CancelToken token);

class IpPortraitView extends ConsumerStatefulWidget {
  const IpPortraitView({super.key, this.dnsProbe});
  final PortraitDnsProbe? dnsProbe;

  @override
  ConsumerState<IpPortraitView> createState() => _IpPortraitViewState();
}

class _IpPortraitViewState extends ConsumerState<IpPortraitView> {
  late final RouteTracker _tracker;
  IpPortraitRunner? _runner;
  CancelToken? _dnsToken;
  IpPortraitReport? _report;
  List<DnsResolverReceipt>? _dns;
  bool _running = false;
  int _generation = 0;
  int _validation = 0;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _tracker = ref.read(routeTrackerProvider.notifier)..attach();
    ref.listenManual(routeTrackerProvider, (before, after) {
      if (before != null &&
          after.invalidatesDiagnostics(before) &&
          (_running || _report != null)) {
        if (before.coreEpoch == after.coreEpoch &&
            before.hostEpoch == after.hostEpoch &&
            before.proxied == after.proxied) {
          if (!_running) unawaited(_validateReport());
          return;
        }
        _cancel();
        setState(() => _notice = context.appLocalizations.auditStale);
      }
    });
  }

  void _release() {
    _generation++;
    _validation++;
    _runner?.cancel();
    _dnsToken?.cancel();
  }

  Future<void> _validateReport() async {
    final report = _report;
    if (report == null) return;
    final validation = ++_validation;
    if (report.receipts.isEmpty ||
        report.receipts.any((receipt) => receipt.hits.isEmpty)) {
      setState(() => _notice = context.appLocalizations.portraitUnclear);
      return;
    }
    RouteCheck? checked;
    try {
      checked = await ref
          .read(coreHandlerProvider)
          .checkRoutes(
            CheckRoutesParams(
              routes: [for (final receipt in report.receipts) receipt.hits],
            ),
          );
    } catch (_) {
      checked = null;
    }
    if (!mounted || validation != _validation || !identical(report, _report)) {
      return;
    }
    if (checked == null || checked.held.length != report.receipts.length) {
      setState(() => _notice = context.appLocalizations.portraitUnclear);
    } else if (report.receipts.any(
          (receipt) => receipt.coreEpoch != checked!.coreEpoch,
        ) ||
        checked.held.any((held) => !held)) {
      _cancel();
      setState(() => _notice = context.appLocalizations.auditStale);
    } else {
      setState(() => _notice = null);
    }
  }

  void _cancel() {
    _release();
    setState(() {
      _running = false;
      _report = null;
      _dns = null;
    });
  }

  @override
  void dispose() {
    _release();
    _tracker.detach();
    super.dispose();
  }

  Future<void> _start() async {
    final route = ref.read(routeTrackerProvider);
    if (!route.synced || !ref.read(isStartProvider)) {
      setState(() => _notice = context.appLocalizations.diagnosticsNeedCore);
      return;
    }
    final generation = ++_generation;
    final core = ref.read(coreHandlerProvider);
    final runner = _runner = IpPortraitRunner(
      request: core.outboundIp,
      probeRoute: core.probe,
      coreEpoch: route.coreEpoch,
      routeVersion: route.routeVersion,
    );
    final token = _dnsToken = CancelToken();
    setState(() {
      _running = true;
      _notice = null;
      _report = null;
      _dns = null;
    });
    final dnsFuture =
        Future.sync(
          () =>
              widget.dnsProbe?.call(token) ??
              DnsLeakProbe(dio: request.dio).run(token, samples: 4),
        ).then<List<DnsResolverReceipt>?>(
          (receipts) => receipts,
          onError: (Object _) => null,
        );
    try {
      final report = await runner.run();
      final dns = await dnsFuture;
      if (!mounted || generation != _generation) return;
      setState(() {
        _report = report;
        _dns = dns;
      });
      if (report.needsRouteValidation ||
          ref.read(routeTrackerProvider).routeVersion != route.routeVersion) {
        await _validateReport();
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _notice = context.appLocalizations.portraitUnclear);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _running = false);
      }
    }
  }

  Widget _panel(String title, List<Widget> children) => CommonCard(
    padding: const EdgeInsets.all(14),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            title,
            style: AppTextStyle.subheadline.of(context, emphasized: true),
          ),
          ...children,
        ],
      ),
    ),
  );

  Widget _text(String value, {bool mono = false}) => Text(
    value,
    style: mono
        ? AppTextStyle.footnote.of(context).toJetBrainsMono
        : AppTextStyle.footnote.of(context),
  );

  String _access(String value) => switch (value) {
    'hosting' => context.appLocalizations.ipTypeHosting,
    'mobile' => context.appLocalizations.ipTypeMobile,
    'business' => context.appLocalizations.ipTypeBusiness,
    'isp' => context.appLocalizations.portraitIsp,
    '' => context.appLocalizations.unknown,
    _ => value,
  };

  Widget _source(IpPortraitObservation source) {
    final l10n = context.appLocalizations;
    return CommonCard(
      child: ExpansionTile(
        title: Text(
          '${source.source.label} · ${source.ip}',
          style: AppTextStyle.footnote.of(context, emphasized: true),
        ),
        subtitle: Text(
          source.error != null
              ? l10n.diagnosticsFailed
              : '${l10n.ipType}: ${_access(source.access)}',
          style: AppTextStyle.caption1.of(context),
        ),
        shape: AppShape.md,
        collapsedShape: AppShape.md,
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (source.error != null)
            _text(l10n.diagnosticsFailed)
          else ...[
            Row(
              spacing: 8,
              children: [
                if (source.country.isNotEmpty)
                  Text(
                    source.country.countryFlagEmoji,
                    style: AppTextStyle.subheadline
                        .of(context)
                        .copyWith(fontFamily: FontFamily.twEmoji.value),
                  ),
                Expanded(
                  child: _text(
                    [
                      source.country,
                      source.city,
                    ].where((value) => value.isNotEmpty).join(' · '),
                  ),
                ),
              ],
            ),
            _text(
              [
                source.organization,
                source.asn,
              ].where((value) => value.isNotEmpty).join(' · '),
            ),
            _text('${l10n.ipType}: ${_access(source.access)}'),
            if (source.reportsRisk) _text(l10n.portraitRiskNoted),
            ExpansionTile(
              title: Text(
                l10n.diagnosticsRawEvidence,
                style: AppTextStyle.footnote.of(context),
              ),
              shape: AppShape.md,
              collapsedShape: AppShape.md,
              children: [
                _text(l10n.portraitMetricsScope),
                if (source.flags.isEmpty && source.metrics.isEmpty)
                  _text(l10n.diagnosticsInsufficient),
                for (final entry in source.flags.entries)
                  _text('${entry.key}: ${entry.value}', mono: true),
                for (final entry in source.metrics.entries)
                  _text('${entry.key}: ${entry.value}', mono: true),
                _text(source.source.url(source.ip), mono: true),
              ],
            ),
          ],
          _text(DateFormat.yMd().add_Hms().format(source.checkedAt.toLocal())),
        ],
      ),
    );
  }

  Widget _exitSummary(IpPortraitReport report, IpExitObservation exit) {
    final l10n = context.appLocalizations;
    final sources = report.sources.where(
      (source) => source.ip == exit.ip && source.error == null,
    );
    final locations = {
      for (final source in sources)
        [
          if (source.country.isNotEmpty)
            countryName(
                  source.country,
                  Localizations.localeOf(context).languageCode,
                ) ??
                source.country,
          if (source.city.isNotEmpty) source.city,
        ].join(' · '),
    }..remove('');
    final types = sources
        .map((source) => source.access)
        .where((value) => value.isNotEmpty)
        .toSet();
    final organizations = sources
        .map((source) => source.organization)
        .where((value) => value.isNotEmpty)
        .toSet();
    return _panel('IPv${exit.family} · ${exit.ip ?? l10n.unknown}', [
      _text(locations.isEmpty ? l10n.unknown : locations.join(' / ')),
      _text(
        '${l10n.statusAccessType}: ${types.isEmpty ? l10n.unknown : types.map(_access).join(" / ")}',
      ),
      if (organizations.isNotEmpty) _text(organizations.join(' / ')),
      _text(
        sources.any((source) => source.reportsRisk)
            ? l10n.portraitRiskNoted
            : sources.any((source) => source.flags.isNotEmpty)
            ? l10n.portraitNoRiskSignals
            : l10n.portraitUnclear,
      ),
      if (exit.route != null)
        ExpansionTile(
          title: Text(
            l10n.toolsServices,
            style: AppTextStyle.footnote.of(context),
          ),
          shape: AppShape.md,
          collapsedShape: AppShape.md,
          children: [_text(exit.route!.chains.reversed.join(' ➜ '))],
        ),
    ]);
  }

  Widget _leaks() {
    final l10n = context.appLocalizations;
    final dnsRisk = _dns?.any((resolver) => resolver.domesticIsp) ?? false;
    return _panel(l10n.toolsPrivacy, [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.dnsLeakTitle, style: AppTextStyle.body.of(context)),
        subtitle: Text(
          dnsRisk ? l10n.dnsLeakRisk : l10n.diagnosticsInsufficient,
          style: AppTextStyle.footnote.of(context),
        ),
        trailing: Text('${_dns?.length ?? 0}'),
        onTap: () => BaseNavigator.push(
          context,
          const NetworkDiagnosticsView(kind: NetworkDiagnostic.dns),
        ),
      ),
      ExpansionTile(
        title: Text(
          l10n.diagnosticsRawEvidence,
          style: AppTextStyle.footnote.of(context),
        ),
        shape: AppShape.md,
        collapsedShape: AppShape.md,
        children: [
          _text(l10n.portraitDnsScope),
          _text(l10n.diagnosticsQuick),
          for (final resolver in _dns ?? <DnsResolverReceipt>[])
            _text(
              '${resolver.ip} · ${resolver.country} · ${resolver.organization}',
            ),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final report = _report;
    final dnsRisk = _dns?.any((resolver) => resolver.domesticIsp) ?? false;
    return BaseScaffold(
      title: l10n.ipPortraitTitle,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              context.appBarInset,
              16,
              24 + context.bottomInset,
            ),
            children: [
              _text(l10n.portraitDataScope),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: _running ? _cancel : _start,
                  child: Text(_running ? l10n.cancel : l10n.start),
                ),
              ),
              if (_running)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _text(_notice!),
                ),
              const SizedBox(height: 12),
              _panel(l10n.diagnosticsConclusion, [
                _text(
                  report == null
                      ? l10n.diagnosticsInsufficient
                      : dnsRisk
                      ? l10n.diagnosticsRisk
                      : report.hasDisagreement
                      ? l10n.portraitSourceConflict
                      : report.hasRisk
                      ? l10n.portraitRiskNoted
                      : report.sources.any((source) => source.flags.isNotEmpty)
                      ? l10n.portraitNoRiskSignals
                      : l10n.portraitUnclear,
                ),
                if (dnsRisk) _text(l10n.dnsLeakRisk),
                if (report != null)
                  _text(
                    DateFormat.yMd().add_Hms().format(
                      report.checkedAt.toLocal(),
                    ),
                  ),
              ]),
              if (report != null) ...[
                const SizedBox(height: 12),
                for (final exit in report.exits) ...[
                  _exitSummary(report, exit),
                  const SizedBox(height: 12),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth >= 720
                        ? (constraints.maxWidth - 12) / 2
                        : constraints.maxWidth;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final source in report.sources)
                          SizedBox(width: width, child: _source(source)),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                _leaks(),
                const SizedBox(height: 12),
                _panel(l10n.toolsServices, [
                  _text(l10n.portraitRoutingScope),
                  for (final target in report.routes)
                    ExpansionTile(
                      title: Text(
                        target.label,
                        style: AppTextStyle.body.of(context),
                      ),
                      subtitle: Text(
                        target.reply?.chains.reversed.join(' ➜ ') ??
                            l10n.unknown,
                        style: AppTextStyle.footnote.of(context),
                      ),
                      shape: AppShape.md,
                      collapsedShape: AppShape.md,
                      children: [
                        _text(target.url, mono: true),
                        if (target.reply case final reply?) ...[
                          _text(
                            'HTTP ${reply.statusCode} · ${reply.delay} ms',
                            mono: true,
                          ),
                          _text(
                            '${reply.rule}, ${reply.rulePayload} ➜ ${reply.chains.reversed.join(" ➜ ")}',
                            mono: true,
                          ),
                        ] else
                          _text(l10n.diagnosticsFailed),
                      ],
                    ),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

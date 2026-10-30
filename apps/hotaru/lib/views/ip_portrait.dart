import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/dns_leak.dart';
import 'package:hotaru/common/ice_probe.dart';
import 'package:hotaru/common/ip_portrait.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'network_diagnostics.dart';

typedef PortraitDnsProbe =
    Future<List<DnsResolverReceipt>> Function(CancelToken token);

class IpPortraitView extends ConsumerStatefulWidget {
  const IpPortraitView({super.key, this.dnsProbe, this.iceProbe});
  final PortraitDnsProbe? dnsProbe;
  final IceProbe Function()? iceProbe;

  @override
  ConsumerState<IpPortraitView> createState() => _IpPortraitViewState();
}

class _IpPortraitViewState extends ConsumerState<IpPortraitView> {
  late final RouteTracker _tracker;
  IpPortraitRunner? _runner;
  CancelToken? _dnsToken;
  IceProbe? _ice;
  IpPortraitReport? _report;
  List<DnsResolverReceipt>? _dns;
  IceProbeResult? _iceResult;
  bool _running = false;
  int _generation = 0;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _tracker = ref.read(routeTrackerProvider.notifier)..attach();
    ref.listenManual(routeTrackerProvider, (before, after) {
      if (before != null && before != after && (_running || _report != null)) {
        _cancel();
        setState(() => _notice = context.appLocalizations.auditStale);
      }
    });
  }

  void _release() {
    _generation++;
    _runner?.cancel();
    _dnsToken?.cancel();
    unawaited(_ice?.cancel());
  }

  void _cancel() {
    _release();
    setState(() {
      _running = false;
      _report = null;
      _dns = null;
      _iceResult = null;
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
    final ice = _ice = widget.iceProbe?.call() ?? IceProbe();
    setState(() {
      _running = true;
      _notice = null;
      _report = null;
      _dns = null;
      _iceResult = null;
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
    final iceFuture = ice.run().then<IceProbeResult?>(
      (result) => result,
      onError: (Object _) => null,
    );
    try {
      final report = await runner.run();
      final dns = await dnsFuture;
      final iceResult = await iceFuture;
      if (!mounted || generation != _generation) return;
      setState(() {
        _report = report;
        _dns = dns;
        _iceResult = iceResult;
      });
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
    'isp' => 'ISP',
    '' => context.appLocalizations.unknown,
    _ => value,
  };

  Widget _source(IpPortraitObservation source) {
    final l10n = context.appLocalizations;
    return _panel('${source.source.label} · ${source.ip}', [
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
    ]);
  }

  Widget _leaks(IpPortraitReport report) {
    final l10n = context.appLocalizations;
    final iceVerdict =
        _iceResult?.verdict(report.addresses) ?? IceVerdict.inconclusive;
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
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.webrtcLeakTitle, style: AppTextStyle.body.of(context)),
        subtitle: Text(switch (iceVerdict) {
          IceVerdict.matching => l10n.webrtcLeakMatch,
          IceVerdict.risk => l10n.webrtcLeakRisk,
          IceVerdict.inconclusive => l10n.diagnosticsInsufficient,
        }, style: AppTextStyle.footnote.of(context)),
        onTap: () => BaseNavigator.push(
          context,
          const NetworkDiagnosticsView(kind: NetworkDiagnostic.stun),
        ),
      ),
      ExpansionTile(
        title: Text(
          l10n.iceCandidates,
          style: AppTextStyle.footnote.of(context),
        ),
        shape: AppShape.md,
        collapsedShape: AppShape.md,
        children: [
          _text(l10n.webrtcLeakScope),
          for (final candidate in _iceResult?.candidates ?? <IceAddress>[])
            _text(
              '${candidate.kind} · ${candidate.protocol} · ${candidate.address}',
              mono: true,
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
    final iceRisk =
        report != null &&
        _iceResult?.verdict(report.addresses) == IceVerdict.risk;
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
                      : dnsRisk || iceRisk
                      ? l10n.diagnosticsRisk
                      : report.hasDisagreement
                      ? l10n.portraitSourceConflict
                      : report.hasRisk
                      ? l10n.portraitRiskNoted
                      : l10n.portraitUnclear,
                ),
                if (dnsRisk) _text(l10n.dnsLeakRisk),
                if (iceRisk) _text(l10n.webrtcLeakRisk),
                if (report != null)
                  _text(
                    DateFormat.yMd().add_Hms().format(
                      report.checkedAt.toLocal(),
                    ),
                  ),
              ]),
              if (report != null) ...[
                const SizedBox(height: 12),
                _panel(l10n.ipPortraitTitle, [
                  for (final exit in report.exits) ...[
                    _text(
                      'IPv${exit.family} · ${exit.ip ?? l10n.unknown}',
                      mono: exit.ip != null,
                    ),
                    if (exit.route != null)
                      _text(exit.route!.chains.reversed.join(' ➜ ')),
                  ],
                  _text('${l10n.statusIpOrigin}: ${l10n.unknown}'),
                  _text(l10n.portraitOriginScope),
                ]),
                const SizedBox(height: 12),
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
                _leaks(report),
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

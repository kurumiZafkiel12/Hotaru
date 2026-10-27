import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hotaru/enum/enum.dart';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/dns_leak.dart';
import 'package:hotaru/common/ip_quality.dart';
import 'package:hotaru/common/network_diagnostics.dart';
import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/features/ip_quality/ip_quality_sheet.dart';
import 'package:hotaru/features/ip_quality/labels.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/ui/ui.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

enum NetworkDiagnostic { dns, stun, ip, recovery }

class NetworkDiagnosticsView extends ConsumerStatefulWidget {
  const NetworkDiagnosticsView({super.key, required this.kind});

  final NetworkDiagnostic kind;

  @override
  ConsumerState<NetworkDiagnosticsView> createState() =>
      _NetworkDiagnosticsViewState();
}

class _NetworkDiagnosticsViewState
    extends ConsumerState<NetworkDiagnosticsView> {
  bool _running = false;
  int _generation = 0;
  final _evidence = <String>[];
  String? _notice;
  String? _ip;
  bool _risk = false;
  List<DnsResolverReceipt> _dnsSystem = const [];
  List<DnsResolverReceipt> _dnsCore = const [];
  IpInfo? _dnsExit;
  DnsLeakVerdict? _dnsVerdict;
  bool _dnsTested = false;
  bool _dnsCoreProbed = false;
  _PortraitData? _portraitData;
  bool _recoverySuperseded = false;
  StunProbe? _stun;
  CancelToken? _httpCancel;
  CancelToken? _qualityCancel;

  @override
  void initState() {
    super.initState();
    ref.listenManual(isStartProvider, (previous, next) {
      if (_running &&
          widget.kind == NetworkDiagnostic.recovery &&
          previous != next) {
        _recoverySuperseded = true;
      }
    });
    ref.listenManual(routeTrackerProvider, (previous, next) {
      if (mounted &&
          previous != null &&
          previous != next &&
          widget.kind != NetworkDiagnostic.recovery &&
          (_running || _evidence.isNotEmpty)) {
        _cancel();
        setState(() {
          _notice = context.appLocalizations.auditStale;
          _risk = false;
          _dnsTested = false;
        });
      }
    });
  }

  String get _title {
    final l10n = context.appLocalizations;
    return switch (widget.kind) {
      NetworkDiagnostic.dns => l10n.dnsLeakTitle,
      NetworkDiagnostic.stun => l10n.webrtcLeakTitle,
      NetworkDiagnostic.ip => l10n.ipPortraitTitle,
      NetworkDiagnostic.recovery => l10n.networkRecoveryTitle,
    };
  }

  String get _scope {
    final l10n = context.appLocalizations;
    return switch (widget.kind) {
      NetworkDiagnostic.dns => l10n.dnsLeakScope,
      NetworkDiagnostic.stun => l10n.webrtcLeakScope,
      NetworkDiagnostic.ip => l10n.ipPortraitScope,
      NetworkDiagnostic.recovery => l10n.networkRecoveryScope,
    };
  }

  @override
  void dispose() {
    _generation++;
    _stun?.cancel();
    _httpCancel?.cancel();
    _qualityCancel?.cancel();
    super.dispose();
  }

  void _cancel() {
    _generation++;
    _stun?.cancel();
    _httpCancel?.cancel();
    _qualityCancel?.cancel();
    setState(() => _running = false);
  }

  Future<void> _start() async {
    if (_running) return;
    if (widget.kind == NetworkDiagnostic.recovery) {
      final agreed = await dialogs.showMessage(
        title: _title,
        message: TextSpan(text: _scope),
      );
      if (agreed != true || !mounted || _running) return;
    } else if (widget.kind != NetworkDiagnostic.dns &&
        !ref.read(isStartProvider)) {
      setState(() => _notice = context.appLocalizations.diagnosticsNeedCore);
      return;
    }
    final generation = ++_generation;
    _httpCancel = CancelToken();
    setState(() {
      _running = true;
      _notice = null;
      _risk = false;
      _recoverySuperseded = false;
      _ip = null;
      _dnsTested = false;
      _dnsVerdict = null;
      _dnsSystem = const [];
      _dnsCore = const [];
      _dnsExit = null;
      _portraitData = null;
      _evidence.clear();
    });
    bool current() => mounted && generation == _generation;
    try {
      switch (widget.kind) {
        case NetworkDiagnostic.dns:
          await _dns(current);
        case NetworkDiagnostic.stun:
          await _checkStun(current);
        case NetworkDiagnostic.ip:
          await _portrait(current);
        case NetworkDiagnostic.recovery:
          await _recover(current);
      }
      if (current()) {
        setState(
          () => _notice ??=
              widget.kind == NetworkDiagnostic.ip && _portraitData != null
              ? null
              : context.appLocalizations.diagnosticsCompleted,
        );
      }
    } catch (error) {
      if (current()) {
        setState(() {
          _notice = context.appLocalizations.diagnosticsFailed;
          _evidence.add(compactError(error));
        });
      }
    } finally {
      if (current()) setState(() => _running = false);
    }
  }

  /// Forces one probe name to resolve through the core by asking for
  /// it over HTTPS via the app proxy; the answer itself is irrelevant.
  Future<List<InternetAddress>> _lookupViaProxy(
    String host,
    String proxy,
  ) async {
    final client = HttpClient();
    client.findProxy = (_) => proxy;
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(Uri.https(host, '/'));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();
    } catch (_) {
      // A refused or unanswered probe still made the core resolve it.
    } finally {
      client.close(force: true);
    }
    return const [];
  }

  Future<void> _dns(bool Function() current) async {
    final l10n = context.appLocalizations;
    IpInfo? exit;
    if (ref.read(isStartProvider)) {
      try {
        exit = await _outbound(current);
      } catch (_) {
        exit = null;
      }
      if (!current()) return;
    }
    final proxy = HotaruHttpOverrides.findProxyForReader(
      ref.read,
      Uri.parse('https://example.com'),
    );
    var system = <DnsResolverReceipt>[];
    try {
      system = await DnsLeakProbe(dio: request.dio).run(_httpCancel!);
    } catch (error) {
      if (!current()) return;
      _evidence.add('bash.ws · ${compactError(error)}');
    }
    if (!current()) return;
    var core = <DnsResolverReceipt>[];
    final coreProbed = proxy.startsWith('PROXY');
    if (coreProbed) {
      try {
        core = await DnsLeakProbe(
          dio: request.dio,
          lookup: (host) => _lookupViaProxy(host, proxy),
        ).run(_httpCancel!);
      } catch (error) {
        if (!current()) return;
        _evidence.add('bash.ws · ${compactError(error)}');
      }
    }
    if (!current()) return;
    system = await enrichResolverHostnames(system);
    core = await enrichResolverHostnames(core);
    if (!current()) return;
    final verdict = judgeDnsLeak([...system, ...core], exit?.countryCode);
    setState(() {
      _dnsSystem = system;
      _dnsCore = core;
      _dnsExit = exit;
      _dnsVerdict = verdict;
      _dnsTested = true;
      _dnsCoreProbed = coreProbed;
      _risk = verdict == DnsLeakVerdict.leaking;
      _notice = switch (verdict) {
        DnsLeakVerdict.leaking => l10n.dnsLeakVerdictLeak,
        DnsLeakVerdict.clean => l10n.dnsLeakVerdictClean,
        DnsLeakVerdict.inconclusive => l10n.dnsLeakUnknown,
      };
      _evidence.add(
        'bash.ws · ${system.length} + ${core.length} · '
        '${DateTime.now().toIso8601String()}',
      );
    });
  }

  Future<IpInfo> _outbound(bool Function() current) async {
    final result = await lookupOutboundIp(
      ref.read(coreHandlerProvider),
      routedOutbound,
    );
    final info = parseOutboundIp(result);
    if (info == null) throw const SocketException('outbound IP unavailable');
    if (current() && mounted) {
      _evidence.add('${context.appLocalizations.outboundIp}: ${info.ip}');
      if (result != null) {
        _evidence.add('${result.url} · ${result.chains.reversed.join(" ➜ ")}');
      }
    }
    return info;
  }

  Future<void> _checkStun(bool Function() current) async {
    final outbound = await _outbound(current);
    if (!current()) return;
    var answers = 0;
    for (final (host, port) in const [
      ('stun.l.google.com', 19302),
      ('stun.cloudflare.com', 3478),
    ]) {
      final probe = StunProbe();
      _stun = probe;
      try {
        final answer = await probe.run(host, port);
        if (!current()) return;
        _evidence.add('$host:$port ➜ $answer');
        final exitAddress = InternetAddress.tryParse(outbound.ip);
        if (isPublicProbeAddress(answer.address) &&
            exitAddress != null &&
            answer.address.type == exitAddress.type) {
          answers++;
          _risk |= answer.address.address != exitAddress.address;
        }
      } catch (error) {
        if (!current()) return;
        _evidence.add('$host:$port · ${compactError(error)}');
      } finally {
        probe.cancel();
      }
    }
    if (!current()) return;
    final interfaces = await NetworkInterface.list(includeLinkLocal: true);
    if (!current()) return;
    _evidence.addAll([
      for (final interface in interfaces)
        for (final address in interface.addresses)
          '${interface.name}: ${address.address}',
    ]);
    setState(
      () => _notice = answers == 0
          ? context.appLocalizations.auditInconclusive
          : _risk
          ? context.appLocalizations.webrtcLeakRisk
          : context.appLocalizations.webrtcLeakMatch,
    );
  }

  Future<(_LeakState, int)> _webrtcVerdict(
    IpInfo exit,
    bool Function() current,
  ) async {
    var answers = 0;
    var mismatch = false;
    final exitAddress = InternetAddress.tryParse(exit.ip);
    for (final (host, port) in const [
      ('stun.l.google.com', 19302),
      ('stun.cloudflare.com', 3478),
    ]) {
      final probe = StunProbe();
      _stun = probe;
      try {
        final answer = await probe.run(host, port);
        if (!current()) return (_LeakState.inconclusive, answers);
        if (isPublicProbeAddress(answer.address) &&
            exitAddress != null &&
            answer.address.type == exitAddress.type) {
          answers++;
          if (answer.address.address != exitAddress.address) {
            mismatch = true;
          }
        }
      } catch (_) {
        // A silent server is no answer, not an answer of any kind.
      } finally {
        probe.cancel();
      }
    }
    return (
      answers == 0
          ? _LeakState.inconclusive
          : mismatch
          ? _LeakState.leak
          : _LeakState.clean,
      answers,
    );
  }

  Future<_LeakState> _dnsLeakVerdict(
    IpInfo exit,
    bool Function() current,
  ) async {
    try {
      final receipts = await DnsLeakProbe(dio: request.dio).run(_httpCancel!);
      if (!current()) return _LeakState.inconclusive;
      return switch (judgeDnsLeak(receipts, exit.countryCode)) {
        DnsLeakVerdict.leaking => _LeakState.leak,
        DnsLeakVerdict.clean => _LeakState.clean,
        DnsLeakVerdict.inconclusive => _LeakState.inconclusive,
      };
    } catch (_) {
      return _LeakState.inconclusive;
    }
  }

  Future<void> _portrait(bool Function() current) async {
    final info = await _outbound(current);
    if (!current()) return;
    setState(() => _ip = info.ip);
    _qualityCancel = CancelToken();
    final dio = request.dio;
    final answers = await Future.wait<Object?>([
      lookupIpQuality(
        dio,
        info.ip,
        cancelToken: _qualityCancel!,
      ).then<Object?>((quality) => quality, onError: (_) => null),
      lookupIpOrigin(dio, info.ip, cancelToken: _qualityCancel!),
      lookupGeoSources(dio, info.ip, cancelToken: _qualityCancel),
      lookupProxyCheckDetails(dio, info.ip, cancelToken: _qualityCancel),
    ]);
    if (!current()) return;
    final (webrtc, stunAnswers) = await _webrtcVerdict(info, current);
    if (!current()) return;
    final dns = await _dnsLeakVerdict(info, current);
    if (!current()) return;
    final response = await ref
        .read(coreHandlerProvider)
        .probe(
          const ProbeParams(
            url: 'https://www.google.com/search?q=hotaru&num=1',
            headers: {'User-Agent': browserUa},
            timeout: 8000,
            maxBody: 64 * 1024,
          ),
        );
    if (!current() || !mounted) return;
    final google = response == null || response.error != null
        ? _LeakState.inconclusive
        : response.statusCode == 429 ||
              RegExp(
                r'g-recaptcha|/sorry/|unusual traffic',
                caseSensitive: false,
              ).hasMatch(response.body)
        ? _LeakState.leak
        : response.statusCode == 200
        ? _LeakState.clean
        : _LeakState.inconclusive;
    if (response != null) {
      _evidence.add('${response.url} · HTTP ${response.statusCode}');
      _evidence.add(
        '${response.rule}, ${response.rulePayload} ➜ ${response.chains.reversed.join(" ➜ ")}',
      );
    }
    setState(() {
      _portraitData = _PortraitData(
        exit: info,
        quality: answers[0] as IpQuality?,
        origin: answers[1] as IpOrigin,
        geoSources: answers[2] as List<GeoSourceResult>,
        proxyCheck: answers[3] as ProxyCheckDetails?,
        webrtc: webrtc,
        stunAnswers: stunAnswers,
        dns: dns,
        google: google,
      );
      _notice = null;
    });
  }

  Future<void> _recover(bool Function() current) async {
    if (!system.isWindows || safeModeBuild) {
      throw UnsupportedError('Windows recovery unavailable');
    }
    final l10n = context.appLocalizations;
    final wasRunning = ref.read(isStartProvider);
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(systemProxy: false));
    final reset =
        await systemProxyQueue?.recover(() => clearWindowsPac(Process.run)) ??
        false;
    if (!current()) return;
    setState(
      () => _evidence.add(
        '${l10n.networkRecoveryProxy}: ${reset ? l10n.done : l10n.diagnosticsFailed}',
      ),
    );
    var dnsCleared = false;
    try {
      final dns = await Process.run('ipconfig.exe', [
        '/flushdns',
      ]).timeout(const Duration(seconds: 15));
      if (!current()) return;
      dnsCleared = dns.exitCode == 0;
      setState(() {
        _evidence.add('${l10n.networkRecoveryDns}: ${dns.exitCode}');
        _evidence.add('${dns.stdout}'.trim());
      });
    } catch (error) {
      if (!current()) return;
      setState(
        () =>
            _evidence.add('${l10n.networkRecoveryDns}: ${compactError(error)}'),
      );
    }
    var recovered = true;
    if (!_recoverySuperseded && wasRunning && ref.read(isStartProvider)) {
      recovered = await ref.read(coreActionProvider.notifier).restartCore();
    } else if (!_recoverySuperseded && !ref.read(isStartProvider)) {
      recovered = await ref
          .read(setupActionProvider.notifier)
          .setRunning(false);
    }
    if (!current()) return;
    setState(() {
      _evidence.add(
        _recoverySuperseded
            ? l10n.networkRecoverySuperseded
            : '${l10n.networkRecoveryTun}: ${recovered ? l10n.done : l10n.diagnosticsFailed}',
      );
      _risk = !reset || !dnsCleared || !recovered;
      _notice = _recoverySuperseded
          ? l10n.networkRecoverySuperseded
          : _risk
          ? l10n.diagnosticsFailed
          : l10n.diagnosticsCompleted;
    });
  }

  Future<void> _applyDoh() async {
    final agreed = await dialogs.showMessage(
      message: TextSpan(text: context.appLocalizations.diagnosticsDohScope),
    );
    if (agreed != true || !mounted) return;
    ref
        .read(patchClashConfigProvider.notifier)
        .update(
          (state) => state.copyWith(
            dns: state.dns.copyWith(
              enable: true,
              nameserver: const [
                'https://cloudflare-dns.com/dns-query',
                'https://dns.google/dns-query',
              ],
            ),
            dnsOverrideKeys: {
              ...state.dnsOverrideKeys,
              DnsOverrideKey.enable,
              DnsOverrideKey.nameserver,
            },
          ),
        );
  }

  Future<void> _setStunBlock(bool enabled) async {
    if (enabled) {
      final agreed = await dialogs.showMessage(
        message: TextSpan(text: context.appLocalizations.webrtcBlockScope),
      );
      if (agreed != true || !mounted) return;
    }
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith(blockCommonStun: enabled));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final recovery = widget.kind == NetworkDiagnostic.recovery;
    return BaseScaffold(
      title: _title,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.appBarInset,
          16,
          24 + context.bottomInset,
        ),
        children: [
          Text(_scope, style: AppTextStyle.footnote.of(context)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _running
                    ? recovery
                          ? null
                          : _cancel
                    : _start,
                icon: GlyphIcon(
                  _running ? AppGlyphs.close : AppGlyphs.playPause(0),
                  fill: 1,
                ),
                label: Text(_running ? l10n.cancel : l10n.start),
              ),
              if (widget.kind == NetworkDiagnostic.dns)
                TonalButton(
                  label: l10n.diagnosticsApplyDoh,
                  onPressed: _running ? null : _applyDoh,
                ),
              if (_ip != null)
                TonalButton(
                  label: l10n.ipPortraitTitle,
                  onPressed: () => showIpQualitySheet(context, ip: _ip!),
                ),
            ],
          ),
          if (widget.kind == NetworkDiagnostic.stun)
            SwitchListTile(
              title: Text(l10n.webrtcBlockAction),
              subtitle: Text(l10n.webrtcBlockScope),
              value: ref.watch(
                patchClashConfigProvider.select(
                  (state) => state.blockCommonStun,
                ),
              ),
              onChanged: _running ? null : _setStunBlock,
            ),
          if (_running)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: LinearProgressIndicator(),
            ),
          if (_notice != null &&
              !(widget.kind == NetworkDiagnostic.dns && _dnsTested))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _notice!,
                style: AppTextStyle.callout
                    .of(context)
                    .copyWith(
                      color: _risk ? context.colorScheme.warning : null,
                    ),
              ),
            ),
          if (widget.kind == NetworkDiagnostic.dns && _dnsTested) ...[
            const SizedBox(height: 16),
            _DnsVerdictCard(
              verdict: _dnsVerdict!,
              notice: _notice ?? '',
              exit: _dnsExit,
              systemCount: _dnsSystem.length,
              coreCount: _dnsCore.length,
              coreProbed: _dnsCoreProbed,
            ),
            if (_dnsSystem.isEmpty && _dnsCore.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  l10n.dnsLeakNoResolvers,
                  style: AppTextStyle.footnote.of(context),
                ),
              ),
            if (_dnsSystem.isNotEmpty)
              _ResolverSection(
                title: l10n.dnsLeakSystemResolvers,
                receipts: _dnsSystem,
              ),
            if (_dnsCore.isNotEmpty)
              _ResolverSection(
                title: l10n.dnsLeakCoreResolvers,
                receipts: _dnsCore,
              ),
            const SizedBox(height: 16),
          ],
          if (widget.kind == NetworkDiagnostic.ip && _portraitData != null) ...[
            const SizedBox(height: 16),
            _PortraitSections(
              data: _portraitData!,
              onOpenStun: () => BaseNavigator.push(
                context,
                const NetworkDiagnosticsView(kind: NetworkDiagnostic.stun),
              ),
              onOpenDns: () => BaseNavigator.push(
                context,
                const NetworkDiagnosticsView(kind: NetworkDiagnostic.dns),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_evidence.isNotEmpty)
            CommonCard(
              padding: const EdgeInsets.all(16),
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    Text(
                      l10n.diagnosticsRawEvidence,
                      style: AppTextStyle.headline.of(context),
                    ),
                    for (final evidence in _evidence)
                      Text(
                        evidence,
                        style: AppTextStyle.footnote
                            .of(context)
                            .toJetBrainsMono,
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

/// The DNS verdict, first on the page: the answer in one line, with
/// the basis counted underneath it.
class _DnsVerdictCard extends StatelessWidget {
  const _DnsVerdictCard({
    required this.verdict,
    required this.notice,
    required this.exit,
    required this.systemCount,
    required this.coreCount,
    required this.coreProbed,
  });

  final DnsLeakVerdict verdict;
  final String notice;
  final IpInfo? exit;
  final int systemCount;
  final int coreCount;
  final bool coreProbed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final color = switch (verdict) {
      DnsLeakVerdict.leaking => colorScheme.error,
      DnsLeakVerdict.clean => colorScheme.success,
      DnsLeakVerdict.inconclusive => colorScheme.warning,
    };
    final exit = this.exit;
    final basis = [
      if (exit != null)
        '${l10n.dnsLeakExitLabel}: ${exit.countryCode} · ${exit.ip}',
      '${l10n.dnsLeakSystemResolvers}: $systemCount',
      if (coreProbed) '${l10n.dnsLeakCoreResolvers}: $coreCount',
    ].join('  ·  ');
    return CommonCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        spacing: 12,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: DecoratedBox(
              decoration: ShapeDecoration(color: color, shape: AppShape.full),
              child: const SizedBox.square(dimension: 12),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(
                  notice,
                  style: AppTextStyle.title3
                      .of(context, emphasized: true)
                      .copyWith(color: color),
                ),
                Text(
                  basis,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One path's resolver table: every resolver that actually answered
/// the probe names, with its country, organization and hostname.
class _ResolverSection extends StatelessWidget {
  const _ResolverSection({required this.title, required this.receipts});

  final String title;
  final List<DnsResolverReceipt> receipts;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              '$title · ${receipts.length}',
              style: AppTextStyle.subheadline.of(context, emphasized: true),
            ),
          ),
          CommonCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < receipts.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _ResolverRow(receipt: receipts[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResolverRow extends StatelessWidget {
  const _ResolverRow({required this.receipt});

  final DnsResolverReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final detail = [
      if (receipt.organization.isNotEmpty) receipt.organization,
      if (receipt.hostname.isNotEmpty) receipt.hostname,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        spacing: 10,
        children: [
          if (receipt.country.length == 2)
            FlagIcon(countryCode: receipt.country, width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 1,
              children: [
                Text(
                  receipt.ip,
                  style: AppTextStyle.subheadline
                      .of(context, emphasized: true)
                      .toJetBrainsMono,
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption1
                        .of(context)
                        .copyWith(color: colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          Text(
            receipt.country.isEmpty ? '—' : receipt.country,
            style: AppTextStyle.subheadline
                .of(context, emphasized: true)
                .copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

enum _LeakState { leak, clean, inconclusive }

class _PortraitData {
  const _PortraitData({
    required this.exit,
    required this.quality,
    required this.origin,
    required this.geoSources,
    required this.proxyCheck,
    required this.webrtc,
    required this.stunAnswers,
    required this.dns,
    required this.google,
  });

  final IpInfo exit;
  final IpQuality? quality;
  final IpOrigin origin;
  final List<GeoSourceResult> geoSources;
  final ProxyCheckDetails? proxyCheck;
  final _LeakState webrtc;
  final int stunAnswers;
  final _LeakState dns;
  final _LeakState google;
}

/// The portrait itself: who this exit is, said by several sources at
/// once — header identity, multi-source location, the named risk
/// coefficient, network facts, and the leak checks folded in.
class _PortraitSections extends StatelessWidget {
  const _PortraitSections({
    required this.data,
    required this.onOpenStun,
    required this.onOpenDns,
  });

  final _PortraitData data;
  final VoidCallback onOpenStun;
  final VoidCallback onOpenDns;

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final quality = data.quality;
    final city = data.geoSources
        .where((source) => source.city != null)
        .firstOrNull
        ?.city;
    final risk = data.proxyCheck?.risk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CommonCard(
          radius: 12,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Row(
                spacing: 12,
                children: [
                  FlagIcon(countryCode: data.exit.countryCode, width: 44),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(
                          data.exit.ip,
                          style: AppTextStyle.title1
                              .of(context, emphasized: true)
                              .toJetBrainsMono,
                        ),
                        Text(
                          [
                            data.exit.countryCode,
                            ?city,
                            ?quality?.organization,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.subheadline
                              .of(context)
                              .copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _PortraitPill(label: data.origin.label(context)),
                  if (quality != null) ...[
                    _PortraitPill(label: quality.type.label(context)),
                    _PortraitPill(
                      label: quality.level.label(context),
                      color: quality.level.color(context),
                    ),
                  ] else
                    _PortraitPill(label: l10n.unknown),
                ],
              ),
            ],
          ),
        ),
        _PortraitSection(
          title: l10n.ipPortraitGeoTitle,
          children: [
            for (final source in data.geoSources)
              _PortraitRow(
                label: source.source,
                value: source.answered ? source.countryCode! : l10n.unknown,
                detail: source.city,
                flag: source.answered ? source.countryCode : null,
              ),
          ],
        ),
        _PortraitSection(
          title: l10n.ipPortraitRiskTitle,
          children: [
            if (risk == null)
              _PortraitRow(label: 'proxycheck.io', value: l10n.unknown)
            else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  spacing: 8,
                  children: [
                    Text(
                      '$risk',
                      style: AppTextStyle.title1
                          .of(context, emphasized: true)
                          .toJetBrainsMono,
                    ),
                    Text(
                      '/ 100 · ${risk < 34
                          ? l10n.ipRiskLow
                          : risk < 67
                          ? l10n.ipRiskMedium
                          : l10n.ipRiskHigh} · proxycheck.io',
                      style: AppTextStyle.subheadline
                          .of(context)
                          .copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              ClipRSuperellipse(
                borderRadius: const BorderRadius.all(Radius.circular(5)),
                child: SizedBox(
                  height: 10,
                  child: Stack(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                        ),
                        child: const SizedBox.expand(),
                      ),
                      FractionallySizedBox(
                        widthFactor: risk / 100,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                colorScheme.success,
                                colorScheme.warning,
                                colorScheme.error,
                              ],
                            ),
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (quality != null &&
                (quality.isProxy ||
                    quality.isVpn ||
                    quality.isTor ||
                    quality.isAbuser))
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (quality.isProxy)
                      _PortraitPill(
                        label: l10n.ipFlagProxy,
                        color: colorScheme.warning,
                      ),
                    if (quality.isVpn)
                      _PortraitPill(
                        label: l10n.ipFlagVpn,
                        color: colorScheme.warning,
                      ),
                    if (quality.isTor)
                      _PortraitPill(
                        label: l10n.ipFlagTor,
                        color: colorScheme.error,
                      ),
                    if (quality.isAbuser)
                      _PortraitPill(
                        label: l10n.ipFlagAbuser,
                        color: colorScheme.error,
                      ),
                  ],
                ),
              ),
            _PortraitRow(
              label: l10n.ipPortraitHumanBot,
              value: l10n.unknown,
              detail: l10n.ipPortraitNoSource,
            ),
          ],
        ),
        _PortraitSection(
          title: l10n.ipPortraitNetworkTitle,
          children: [
            _PortraitRow(
              label: l10n.ipPortraitRange,
              value: data.proxyCheck?.range ?? l10n.unknown,
              mono: true,
            ),
            _PortraitRow(
              label: 'ASN',
              value: quality?.asn == null ? l10n.unknown : 'AS${quality!.asn}',
            ),
            _PortraitRow(
              label: l10n.ipPortraitOrg,
              value: quality?.organization ?? l10n.unknown,
            ),
            _PortraitRow(
              label: l10n.hostname,
              value: data.proxyCheck?.hostname ?? l10n.unknown,
            ),
            _PortraitRow(
              label: 'Google',
              value: switch (data.google) {
                _LeakState.clean => l10n.auditReachable,
                _LeakState.leak => l10n.auditChallenge,
                _LeakState.inconclusive => l10n.auditInconclusive,
              },
            ),
          ],
        ),
        _PortraitSection(
          title: l10n.ipPortraitLeakTitle,
          children: [
            _LeakRow(
              label: l10n.webrtcLeakTitle,
              state: data.webrtc,
              cleanLabel: l10n.webrtcLeakMatch,
              leakLabel: l10n.webrtcLeakRisk,
              onOpen: onOpenStun,
            ),
            _LeakRow(
              label: l10n.dnsLeakTitle,
              state: data.dns,
              cleanLabel: l10n.dnsLeakVerdictClean,
              leakLabel: l10n.dnsLeakVerdictLeak,
              onOpen: onOpenDns,
            ),
          ],
        ),
      ],
    );
  }
}

class _PortraitSection extends StatelessWidget {
  const _PortraitSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: AppTextStyle.subheadline.of(context, emphasized: true),
            ),
          ),
          CommonCard(
            radius: 12,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _PortraitRow extends StatelessWidget {
  const _PortraitRow({
    required this.label,
    required this.value,
    this.detail,
    this.flag,
    this.mono = false,
  });

  final String label;
  final String value;
  final String? detail;
  final String? flag;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    var valueStyle = AppTextStyle.subheadline.of(context, emphasized: true);
    if (mono) valueStyle = valueStyle.toJetBrainsMono;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        spacing: 10,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.subheadline
                  .of(context)
                  .copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
          if (flag != null) FlagIcon(countryCode: flag, width: 20),
          Expanded(
            child: Text(
              [value, ?detail].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: valueStyle,
            ),
          ),
        ],
      ),
    );
  }
}

class _PortraitPill extends StatelessWidget {
  const _PortraitPill({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final foreground = color ?? colorScheme.onSurfaceVariant;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: foreground.withValues(alpha: 0.14),
        shape: AppShape.full,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: AppTextStyle.caption1
              .of(context, emphasized: true)
              .copyWith(color: foreground),
        ),
      ),
    );
  }
}

class _LeakRow extends StatelessWidget {
  const _LeakRow({
    required this.label,
    required this.state,
    required this.cleanLabel,
    required this.leakLabel,
    required this.onOpen,
  });

  final String label;
  final _LeakState state;
  final String cleanLabel;
  final String leakLabel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final (text, color) = switch (state) {
      _LeakState.clean => (cleanLabel, colorScheme.success),
      _LeakState.leak => (leakLabel, colorScheme.error),
      _LeakState.inconclusive => (l10n.auditInconclusive, colorScheme.warning),
    };
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          spacing: 10,
          children: [
            Expanded(
              child: Text(
                label,
                style: AppTextStyle.subheadline.of(context, emphasized: true),
              ),
            ),
            Text(
              text,
              style: AppTextStyle.subheadline
                  .of(context, emphasized: true)
                  .copyWith(color: color),
            ),
            GlyphIcon(
              AppGlyphs.chevronForward,
              size: 16,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

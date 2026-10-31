import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hotaru/enum/enum.dart';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/browser_leak_result.dart';
import 'package:hotaru/common/country_names.dart';
import 'package:hotaru/common/ip_quality.dart';
import 'package:hotaru/common/dns_leak.dart';
import 'package:hotaru/common/network_diagnostics.dart';
import 'package:hotaru/common/ice_probe.dart';
import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/features/browser_diagnostics/browser_leak_probe.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

enum NetworkDiagnostic { dns, stun, recovery }

class NetworkDiagnosticsView extends ConsumerStatefulWidget {
  const NetworkDiagnosticsView({
    super.key,
    required this.kind,
    this.browserProbeFactory,
  });

  final NetworkDiagnostic kind;
  final BrowserLeakProbe Function()? browserProbeFactory;

  @override
  ConsumerState<NetworkDiagnosticsView> createState() =>
      _NetworkDiagnosticsViewState();
}

class _NetworkDiagnosticsViewState
    extends ConsumerState<NetworkDiagnosticsView> {
  bool _running = false;
  DiagnosticVerdict _verdict = DiagnosticVerdict.notTested;
  List<DnsResolverReceipt> _resolvers = const [];
  int _dnsSamples = 16;
  double _progress = 0;
  int _generation = 0;
  final _evidence = <String>[];
  String? _notice;
  bool _risk = false;
  bool _recoverySuperseded = false;
  IceProbe? _ice;
  IceProbeResult? _iceResult;
  BrowserLeakProbe? _browserProbe;
  BrowserLeakResult? _browserResult;
  bool _browserFailed = false;
  CancelToken? _httpCancel;
  CancelToken? _qualityCancel;

  bool get _usesBrowser =>
      system.isWindows || widget.browserProbeFactory != null;

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
          next.invalidatesDiagnostics(previous) &&
          widget.kind != NetworkDiagnostic.recovery &&
          (_running || _evidence.isNotEmpty)) {
        if (previous.hostEpoch == next.hostEpoch &&
            previous.coreEpoch == next.coreEpoch &&
            previous.proxied == next.proxied &&
            (_usesBrowser || widget.kind == NetworkDiagnostic.dns)) {
          return;
        }
        _cancel();
        setState(() {
          _notice = context.appLocalizations.auditStale;
          _risk = false;
        });
      }
    });
  }

  String get _title {
    final l10n = context.appLocalizations;
    return switch (widget.kind) {
      NetworkDiagnostic.dns => l10n.dnsLeakTitle,
      NetworkDiagnostic.stun => l10n.webrtcLeakTitle,
      NetworkDiagnostic.recovery => l10n.networkRecoveryTitle,
    };
  }

  String get _scope {
    final l10n = context.appLocalizations;
    if (_usesBrowser && widget.kind != NetworkDiagnostic.recovery) {
      return l10n.browserLeakScope;
    }
    return switch (widget.kind) {
      NetworkDiagnostic.dns => l10n.dnsLeakScope,
      NetworkDiagnostic.stun => l10n.webrtcLeakScope,
      NetworkDiagnostic.recovery => l10n.networkRecoveryScope,
    };
  }

  @override
  void dispose() {
    _generation++;
    _browserProbe?.cancel();
    unawaited(_ice?.cancel());
    _httpCancel?.cancel();
    _qualityCancel?.cancel();
    super.dispose();
  }

  void _cancel() {
    _generation++;
    _browserProbe?.cancel();
    unawaited(_ice?.cancel());
    _httpCancel?.cancel();
    _qualityCancel?.cancel();
    setState(() {
      _running = false;
      _verdict = DiagnosticVerdict.inconclusive;
      _notice = context.appLocalizations.cancel;
    });
  }

  Future<void> _start() async {
    if (_running) return;
    if (widget.kind == NetworkDiagnostic.recovery) {
      final agreed = await dialogs.showMessage(
        title: _title,
        message: TextSpan(text: _scope),
      );
      if (agreed != true || !mounted || _running) return;
    } else if (!_usesBrowser &&
        widget.kind != NetworkDiagnostic.dns &&
        !ref.read(isStartProvider)) {
      setState(() => _notice = context.appLocalizations.diagnosticsNeedCore);
      return;
    }
    final generation = ++_generation;
    _httpCancel = CancelToken();
    setState(() {
      _running = true;
      _verdict = DiagnosticVerdict.running;
      _progress = 0;
      _resolvers = const [];
      _notice = null;
      _risk = false;
      _recoverySuperseded = false;
      _iceResult = null;
      _browserResult = null;
      _browserFailed = false;
      _evidence.clear();
    });
    bool current() => mounted && generation == _generation;
    try {
      if (_usesBrowser && widget.kind != NetworkDiagnostic.recovery) {
        await _browser(current);
      } else {
        switch (widget.kind) {
          case NetworkDiagnostic.dns:
            await _dns(current);
          case NetworkDiagnostic.stun:
            await _checkStun(current);
          case NetworkDiagnostic.recovery:
            await _recover(current);
        }
      }
      if (current() && !_usesBrowser) {
        setState(
          () => _notice ??= context.appLocalizations.diagnosticsCompleted,
        );
      }
    } catch (error) {
      if (current()) {
        setState(() {
          _verdict = DiagnosticVerdict.failed;
          _notice = context.appLocalizations.diagnosticsFailed;
          _evidence.add(compactError(error));
        });
      }
    } finally {
      if (current()) {
        setState(() {
          _running = false;
          if (_verdict == DiagnosticVerdict.running) {
            _verdict = _risk
                ? DiagnosticVerdict.risk
                : widget.kind == NetworkDiagnostic.recovery
                ? DiagnosticVerdict.completed
                : DiagnosticVerdict.inconclusive;
          }
        });
      }
    }
  }

  Future<void> _browser(bool Function() current) async {
    final probe = _browserProbe =
        widget.browserProbeFactory?.call() ?? BrowserLeakProbe();
    try {
      final result = await probe.run(
        widget.kind == NetworkDiagnostic.dns
            ? BrowserLeakKind.dns
            : BrowserLeakKind.webrtc,
        await appPath.tempPath,
      );
      if (!current()) return;
      setState(() {
        _browserResult = result;
        _resolvers = result.resolvers;
        _risk = result.kind == BrowserLeakKind.dns
            ? result.hasDnsRisk
            : result.hasRtcMismatch;
        _verdict = _risk
            ? DiagnosticVerdict.risk
            : result.completed &&
                  result.kind == BrowserLeakKind.dns &&
                  result.resolvers.isNotEmpty
            ? DiagnosticVerdict.completed
            : result.rtcMatches
            ? DiagnosticVerdict.matching
            : DiagnosticVerdict.inconclusive;
        _evidence.add(
          'BrowserLeaks · WebView2 · ${DateTime.now().toIso8601String()}',
        );
      });
    } catch (_) {
      if (current()) {
        setState(() {
          _verdict = DiagnosticVerdict.failed;
          _browserFailed = true;
        });
      }
    }
  }

  String? get _browserNotice {
    final l10n = context.appLocalizations;
    if (_browserFailed) return l10n.browserLeakUnavailable;
    final result = _browserResult;
    if (result == null) return null;
    if (!result.completed) return l10n.browserLeakIncomplete;
    if (result.kind == BrowserLeakKind.dns) {
      return result.hasDnsRisk ? l10n.dnsLeakRisk : l10n.browserDnsObserved;
    }
    return result.hasRtcMismatch
        ? l10n.browserRtcMismatch
        : result.rtcMatches
        ? l10n.browserRtcMatch
        : l10n.iceInconclusive;
  }

  Future<void> _dns(bool Function() current) async {
    try {
      final receipts = await DnsLeakProbe(dio: request.dio).run(
        _httpCancel!,
        samples: _dnsSamples,
        onProgress: (done, total) {
          if (current()) setState(() => _progress = done / total);
        },
      );
      if (!current()) return;
      _evidence.add(
        'bash.ws · $_dnsSamples DNS · ${DateTime.now().toIso8601String()}',
      );
      for (final receipt in receipts) {
        _evidence.add(
          '${receipt.ip} · ${receipt.country} · ${receipt.organization}',
        );
      }
      if (receipts.isNotEmpty) {
        setState(() {
          _resolvers = receipts;
          _risk = receipts.any((receipt) => receipt.domesticIsp);
          _verdict = _risk
              ? DiagnosticVerdict.risk
              : DiagnosticVerdict.inconclusive;
          _notice = _risk
              ? context.appLocalizations.dnsLeakRisk
              : context.appLocalizations.dnsEvidenceLimits;
        });
        return;
      }
    } catch (error) {
      if (!current()) return;
      _evidence.add('bash.ws · ${compactError(error)}');
    }
    final addresses = await InternetAddress.lookup(
      'whoami.akamai.net',
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 8));
    if (!current()) return;
    _evidence.add('whoami.akamai.net · ${DateTime.now().toIso8601String()}');
    var classified = 0;
    for (final address in addresses) {
      _evidence.add(address.address);
      if (!isPublicProbeAddress(address)) continue;
      try {
        _qualityCancel = CancelToken();
        final quality = await lookupIpQuality(
          request.dio,
          address.address,
          cancelToken: _qualityCancel!,
        );
        if (!current()) return;
        final organization = quality.organization ?? '';
        _evidence.add(
          '$organization · AS${quality.asn ?? "—"} · ${quality.source.name}',
        );
        classified++;
        if (RegExp(
          r'china\s*(telecom|unicom|mobile)|chinanet|中国电信|中国联通|中国移动',
          caseSensitive: false,
        ).hasMatch(organization)) {
          _risk = true;
        }
      } catch (error) {
        if (!current()) return;
        _evidence.add(compactError(error));
      }
    }
    if (current()) {
      setState(() {
        _notice = _risk
            ? context.appLocalizations.dnsLeakRisk
            : classified == 0
            ? context.appLocalizations.dnsLeakUnknown
            : context.appLocalizations.dnsLeakScope;
      });
    }
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
    final probe = _ice = IceProbe();
    final result = await probe.run();
    if (!current()) return;
    final verdict = result.verdict([outbound.ip]);
    setState(() {
      _verdict = switch (verdict) {
        IceVerdict.matching => DiagnosticVerdict.matching,
        IceVerdict.risk => DiagnosticVerdict.risk,
        IceVerdict.inconclusive => DiagnosticVerdict.inconclusive,
      };
      _iceResult = result;
      _risk = verdict == IceVerdict.risk;
      _notice = switch (verdict) {
        IceVerdict.matching => context.appLocalizations.iceMatching,
        IceVerdict.risk => context.appLocalizations.webrtcLeakRisk,
        IceVerdict.inconclusive => context.appLocalizations.iceInconclusive,
      };
      _evidence.add(
        'ICE · ${DateTime.now().toIso8601String()} · ${result.completed}',
      );
      if (result.error != null) _evidence.add('ICE: ${result.error}');
      for (final candidate in result.candidates) {
        _evidence.add(
          '${candidate.kind} · ${candidate.protocol} · ${candidate.address}:${candidate.port}',
        );
      }
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
      _verdict = _recoverySuperseded
          ? DiagnosticVerdict.inconclusive
          : _risk
          ? DiagnosticVerdict.failed
          : DiagnosticVerdict.completed;
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
    final notice = _notice ?? _browserNotice;
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: LinearProgressIndicator(
                value: widget.kind == NetworkDiagnostic.dns && _progress > 0
                    ? _progress
                    : null,
              ),
            ),
          const SizedBox(height: 12),
          CommonCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text(
                  l10n.diagnosticsConclusion,
                  style: AppTextStyle.caption1.of(context),
                ),
                Text(
                  _verdict.label,
                  style: AppTextStyle.title3
                      .of(context, emphasized: true)
                      .copyWith(
                        color: _risk ? context.colorScheme.warning : null,
                      ),
                ),
                if (notice != null)
                  Text(notice, style: AppTextStyle.footnote.of(context)),
              ],
            ),
          ),
          if (widget.kind == NetworkDiagnostic.dns) ...[
            const SizedBox(height: 12),
            if (!_usesBrowser)
              DropdownButton<int>(
                value: _dnsSamples,
                onChanged: _running
                    ? null
                    : (samples) => setState(() => _dnsSamples = samples!),
                items: [
                  DropdownMenuItem(
                    value: 4,
                    child: Text(l10n.diagnosticsQuick),
                  ),
                  DropdownMenuItem(
                    value: 16,
                    child: Text(l10n.diagnosticsFull),
                  ),
                ],
              ),
            for (final resolver in _resolvers)
              CommonCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(
                      resolver.ip,
                      style: AppTextStyle.subheadline
                          .of(context)
                          .toJetBrainsMono,
                    ),
                    Text(
                      '${countryName(resolver.country, Localizations.localeOf(context).languageCode) ?? l10n.unknown} · ${resolver.organization}',
                      style: AppTextStyle.footnote.of(context),
                    ),
                  ],
                ),
              ),
          ],
          if (_browserResult case final result?)
            if (result.kind == BrowserLeakKind.webrtc)
              CommonCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    Text(
                      '${l10n.browserRemoteIp}: ${result.remote.isEmpty ? l10n.unknown : result.remote.join(', ')}',
                    ),
                    Text(
                      '${l10n.browserRtcPublicIp}: ${result.public.isEmpty ? l10n.unknown : result.public.join(', ')}',
                    ),
                    Text(
                      '${l10n.browserLocalIp}: ${result.local.isEmpty ? l10n.browserLocalNotExposed : result.local.join(', ')}',
                    ),
                  ],
                ),
              ),
          if (_iceResult case final result?)
            CommonCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(
                    l10n.iceCandidates,
                    style: AppTextStyle.subheadline.of(
                      context,
                      emphasized: true,
                    ),
                  ),
                  Text(
                    l10n.iceCandidateScope,
                    style: AppTextStyle.footnote.of(context),
                  ),
                  for (final candidate in result.candidates)
                    Text(
                      '${candidate.kind} · ${candidate.protocol} · ${candidate.address}',
                      style: AppTextStyle.footnote.of(context).toJetBrainsMono,
                    ),
                ],
              ),
            ),
          if (_evidence.isNotEmpty)
            CommonCard(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                title: Text(l10n.diagnosticsRawEvidence),
                shape: AppShape.lg,
                collapsedShape: AppShape.lg,
                childrenPadding: const EdgeInsets.all(12),
                children: [
                  SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 12,
                      children: [
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
                ],
              ),
            ),
        ],
      ),
    );
  }
}

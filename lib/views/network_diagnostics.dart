import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hotaru/enum/enum.dart';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/ip_quality.dart';
import 'package:hotaru/common/dns_leak.dart';
import 'package:hotaru/common/network_diagnostics.dart';
import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/features/ip_quality/ip_quality_sheet.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
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
          () => _notice ??= context.appLocalizations.diagnosticsCompleted,
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

  Future<void> _dns(bool Function() current) async {
    try {
      final receipts = await DnsLeakProbe(dio: request.dio).run(_httpCancel!);
      if (!current()) return;
      _evidence.add('bash.ws · 16 DNS · ${DateTime.now().toIso8601String()}');
      for (final receipt in receipts) {
        _evidence.add(
          '${receipt.ip} · ${receipt.country} · ${receipt.organization}',
        );
      }
      if (receipts.isNotEmpty) {
        setState(() {
          _risk = receipts.any((receipt) => receipt.domesticIsp);
          _notice = _risk
              ? context.appLocalizations.dnsLeakRisk
              : context.appLocalizations.dnsLeakScope;
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

  Future<void> _portrait(bool Function() current) async {
    final info = await _outbound(current);
    if (!current()) return;
    setState(() => _ip = info.ip);
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
    if (response == null || response.error != null) {
      _notice = context.appLocalizations.auditInconclusive;
      return;
    }
    final challenge =
        response.statusCode == 429 ||
        RegExp(
          r'g-recaptcha|/sorry/|unusual traffic',
          caseSensitive: false,
        ).hasMatch(response.body);
    setState(() {
      _risk = challenge;
      _notice = challenge
          ? context.appLocalizations.auditChallenge
          : response.statusCode == 200
          ? context.appLocalizations.auditReachable
          : context.appLocalizations.auditInconclusive;
      _evidence.add('${response.url} · HTTP ${response.statusCode}');
      _evidence.add(
        '${response.rule}, ${response.rulePayload} ➜ ${response.chains.reversed.join(" ➜ ")}',
      );
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
          if (_notice != null)
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

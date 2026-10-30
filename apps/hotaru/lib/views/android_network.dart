import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotaru/common/android_network.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/providers/android_network.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'network_diagnostics.dart';
import 'dns_queries.dart';

class AndroidNetworkView extends ConsumerStatefulWidget {
  const AndroidNetworkView({super.key});

  @override
  ConsumerState<AndroidNetworkView> createState() => _AndroidNetworkViewState();
}

class _AndroidNetworkViewState extends ConsumerState<AndroidNetworkView>
    with WidgetsBindingObserver {
  bool _opening = false;
  bool _settingsUnavailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      ref.invalidate(androidNetworkSnapshotProvider);
    }
  }

  Future<void> _open(AndroidNetworkSetting setting) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _settingsUnavailable = false;
    });
    try {
      final opened = await ref.read(androidNetworkSettingsProvider)(setting);
      if (mounted) setState(() => _settingsUnavailable = !opened);
    } catch (_) {
      if (mounted) setState(() => _settingsUnavailable = true);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String _flag(bool? value) => value == null
      ? context.appLocalizations.unknown
      : value
      ? context.appLocalizations.yes
      : context.appLocalizations.no;
  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      spacing: 12,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: AppTextStyle.footnote.of(context))),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: AppTextStyle.footnote.of(context, emphasized: true),
          ),
        ),
      ],
    ),
  );
  Widget _card(List<Widget> children) => CommonCard(
    padding: const EdgeInsets.all(14),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: children,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final state = ref.watch(androidNetworkSnapshotProvider);
    final snapshot = state.isLoading
        ? const AndroidNetworkSnapshot(readable: false)
        : state.value ?? const AndroidNetworkSnapshot(readable: false);
    final running = ref.watch(isStartProvider);
    final privateDns = snapshot.api > 0 && snapshot.api < 28
        ? l10n.speedTestNotSupported
        : _flag(snapshot.privateDnsActive);
    final transports = snapshot.transports
        .map(
          (transport) => switch (transport) {
            'wifi' => 'Wi-Fi',
            'cellular' => l10n.ipTypeMobile,
            'vpn' => 'VPN',
            'ethernet' => 'Ethernet',
            'bluetooth' => 'Bluetooth',
            _ => transport,
          },
        )
        .join(' · ');
    return CommonScaffold(
      title: l10n.androidNetworkTitle,
      actions: [
        AppBarActionButton(
          data: IconButtonData(
            glyph: AppGlyphs.refresh,
            tooltip: l10n.ipQualityRetry,
            isLoading: state.isLoading,
            onPressed: () => ref.invalidate(androidNetworkSnapshotProvider),
          ),
        ),
      ],
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              context.appBarInset,
              16,
              24 + context.bottomInset,
            ),
            children: [
              Text(
                l10n.androidNetworkScope,
                style: AppTextStyle.footnote.of(context),
              ),
              const SizedBox(height: 12),
              if (state.isLoading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CommonCircleLoading()),
                ),
              if (!state.isLoading && !snapshot.readable)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    l10n.androidNetworkUnavailable,
                    style: AppTextStyle.body.of(context),
                  ),
                ),
              _card([
                _row(appName, running ? l10n.running : l10n.notRunning),
                _row(l10n.androidSystemVpn, _flag(snapshot.vpn)),
                _row(
                  l10n.network,
                  snapshot.active == false
                      ? l10n.noNetwork
                      : _flag(snapshot.active),
                ),
                _row(
                  l10n.networkType,
                  transports.isEmpty ? l10n.unknown : transports,
                ),
                _row(l10n.androidNetworkValidated, _flag(snapshot.validated)),
                _row(l10n.androidCaptivePortal, _flag(snapshot.captivePortal)),
                _row(l10n.androidMetered, _flag(snapshot.metered)),
              ]),
              const SizedBox(height: 12),
              _card([
                _row(l10n.androidPrivateDns, privateDns),
                if (snapshot.privateDnsName.isNotEmpty)
                  Text(
                    snapshot.privateDnsName,
                    style: AppTextStyle.footnote.of(context).toJetBrainsMono,
                  ),
                Text(
                  l10n.androidDnsServers,
                  style: AppTextStyle.subheadline.of(context, emphasized: true),
                ),
                if (snapshot.dnsServers.isEmpty)
                  Text(l10n.unknown, style: AppTextStyle.footnote.of(context)),
                for (final server in snapshot.dnsServers)
                  Text(
                    server,
                    style: AppTextStyle.footnote.of(context).toJetBrainsMono,
                  ),
                ExpansionTile(
                  title: Text(
                    l10n.diagnosticsRawEvidence,
                    style: AppTextStyle.footnote.of(context),
                  ),
                  shape: AppShape.md,
                  collapsedShape: AppShape.md,
                  children: [
                    _row(
                      'Android API',
                      snapshot.api > 0 ? '${snapshot.api}' : l10n.unknown,
                    ),
                    _row(
                      'MTU',
                      snapshot.mtu == null ? l10n.unknown : '${snapshot.mtu}',
                    ),
                  ],
                ),
              ]),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TonalButton(
                    label: 'VPN',
                    onPressed: _opening
                        ? null
                        : () => _open(AndroidNetworkSetting.vpn),
                  ),
                  TonalButton(
                    label: l10n.androidPrivateDns,
                    onPressed: _opening || snapshot.api < 28
                        ? null
                        : () => _open(AndroidNetworkSetting.privateDns),
                  ),
                  TonalButton(
                    label: l10n.androidWifiSettings,
                    onPressed: _opening
                        ? null
                        : () => _open(AndroidNetworkSetting.wifi),
                  ),
                  TonalButton(
                    label: l10n.androidAppSettings,
                    onPressed: _opening
                        ? null
                        : () => _open(AndroidNetworkSetting.application),
                  ),
                ],
              ),
              if (_settingsUnavailable)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l10n.androidSettingsUnavailable,
                    style: AppTextStyle.footnote.of(context),
                  ),
                ),
              const SizedBox(height: 12),
              ListItem.open(
                title: Text(l10n.dnsQueries),
                widget: const DnsQueriesView(),
              ),
              ListItem.open(
                title: Text(l10n.dnsLeakTitle),
                widget: const NetworkDiagnosticsView(
                  kind: NetworkDiagnostic.dns,
                ),
              ),
              ListItem.open(
                title: Text(l10n.webrtcLeakTitle),
                widget: const NetworkDiagnosticsView(
                  kind: NetworkDiagnostic.stun,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

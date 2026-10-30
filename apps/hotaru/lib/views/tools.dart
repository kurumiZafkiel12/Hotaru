import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'speed_test.dart';
import 'service_audit.dart';
import 'network_diagnostics.dart';
import 'node_geo.dart';
import 'ip_portrait.dart';
import 'android_network.dart';
import 'dashboard/widgets/service_status.dart';

class ToolsView extends ConsumerStatefulWidget {
  const ToolsView({super.key, this.platform});

  final SupportPlatform? platform;

  @override
  ConsumerState<ToolsView> createState() => _ToolViewState();
}

class _ToolViewState extends ConsumerState<ToolsView> {
  Widget _buildNavigationMenuItem(NavigationItem navigationItem) {
    return ListItem.open(
      leading: GlyphIcon(navigationItem.glyph),
      title: Text(navigationItem.label.label),
      widget: navigationItem.builder(context),
      forceFull: navigationItem.modes.contains(NavigationItemMode.moreFull),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      _ToolMatrix(platform: widget.platform ?? SupportPlatform.currentPlatform),
      Consumer(
        builder: (_, ref, _) {
          final state = ref.watch(moreToolsSelectorStateProvider);
          if (state.navigationItems.isEmpty) {
            return Container();
          }
          return generateSection(
            items: state.navigationItems.map(_buildNavigationMenuItem),
          );
        },
      ),
    ];
    return CommonScaffold(
      title: context.appLocalizations.tools,
      body: Builder(
        builder: (context) => ListView.builder(
          key: toolsStoreKey,
          itemCount: items.length,
          itemBuilder: (_, index) => items[index],
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: context.sectionsTopPadding,
            bottom: 20 + context.bottomInset,
          ),
        ),
      ),
    );
  }
}

class _ToolMatrix extends StatelessWidget {
  const _ToolMatrix({required this.platform});

  final SupportPlatform platform;

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final tools = <(String, String, String, Glyph, Widget)>[
      (
        l10n.toolsConnection,
        l10n.serviceStatus,
        l10n.connectivityScope,
        AppGlyphs.verified,
        const ServiceStatusSheet(),
      ),
      (
        l10n.toolsServices,
        l10n.auditTitle,
        l10n.auditSubtitle,
        AppGlyphs.verified,
        const ServiceAuditView(),
      ),
      (
        l10n.toolsConnection,
        l10n.speedTest,
        l10n.networkSpeed,
        AppGlyphs.speed,
        const SpeedTestView(),
      ),
      (
        l10n.toolsPrivacy,
        l10n.dnsLeakTitle,
        l10n.dnsLeakSubtitle,
        AppGlyphs.devices,
        const NetworkDiagnosticsView(kind: NetworkDiagnostic.dns),
      ),
      (
        l10n.toolsPrivacy,
        l10n.webrtcLeakTitle,
        l10n.webrtcLeakSubtitle,
        AppGlyphs.vpn,
        const NetworkDiagnosticsView(kind: NetworkDiagnostic.stun),
      ),
      (
        l10n.toolsIp,
        l10n.ipPortraitTitle,
        l10n.ipPortraitSubtitle,
        AppGlyphs.status,
        const IpPortraitView(),
      ),
      (
        l10n.toolsIp,
        l10n.nodeGlobeTitle,
        l10n.nodeGeoEstimate,
        AppGlyphs.proxies,
        const NodeGeoView(),
      ),
      if (platform == SupportPlatform.Android)
        (
          l10n.toolsMaintenance,
          l10n.androidNetworkTitle,
          l10n.androidNetworkSubtitle,
          AppGlyphs.settings,
          const AndroidNetworkView(),
        ),
      if (platform == SupportPlatform.Windows)
        (
          l10n.toolsMaintenance,
          l10n.networkRecoveryTitle,
          l10n.networkRecoverySubtitle,
          AppGlyphs.settings,
          const NetworkDiagnosticsView(kind: NetworkDiagnostic.recovery),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobile = platform == SupportPlatform.Android;
        final columns = mobile || constraints.maxWidth < 620
            ? 1
            : constraints.maxWidth >= 1000
            ? 3
            : 2;
        final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final group in tools.map((tool) => tool.$1).toSet()) ...[
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 8),
                child: Text(
                  group,
                  style: AppTextStyle.subheadline.of(context, emphasized: true),
                ),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  for (final (category, title, subtitle, glyph, page) in tools)
                    if (category == group)
                      SizedBox(
                        width: width,
                        child: CommonCard(
                          padding: const EdgeInsets.all(12),
                          onPressed: () => BaseNavigator.push(context, page),
                          child: Row(
                            spacing: 12,
                            children: [
                              GlyphIcon(
                                glyph,
                                color: context.colorScheme.primary,
                                size: 24,
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  spacing: 4,
                                  children: [
                                    Text(
                                      title,
                                      style: AppTextStyle.subheadline.of(
                                        context,
                                        emphasized: true,
                                      ),
                                    ),
                                    Text(
                                      subtitle,
                                      style: AppTextStyle.caption1
                                          .of(context)
                                          .copyWith(
                                            color: context
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const GlyphIcon(
                                AppGlyphs.chevronForward,
                                size: 16,
                              ),
                            ],
                          ),
                        ),
                      ),
                ],
              ),
            ],
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

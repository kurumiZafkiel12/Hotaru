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
      _ToolMatrix(platform: widget.platform ?? SupportPlatform.currentPlatform),
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
    final tools = <(String, String, Glyph, Widget)>[
      (
        l10n.auditTitle,
        l10n.auditSubtitle,
        AppGlyphs.verified,
        const ServiceAuditView(),
      ),
      (
        l10n.speedTest,
        l10n.networkSpeed,
        AppGlyphs.speed,
        const SpeedTestView(),
      ),
      (
        l10n.dnsLeakTitle,
        l10n.dnsLeakSubtitle,
        AppGlyphs.devices,
        const NetworkDiagnosticsView(kind: NetworkDiagnostic.dns),
      ),
      (
        l10n.webrtcLeakTitle,
        l10n.webrtcLeakSubtitle,
        AppGlyphs.vpn,
        const NetworkDiagnosticsView(kind: NetworkDiagnostic.stun),
      ),
      (
        l10n.ipPortraitTitle,
        l10n.ipPortraitSubtitle,
        AppGlyphs.status,
        const NetworkDiagnosticsView(kind: NetworkDiagnostic.ip),
      ),
      if (platform == SupportPlatform.Windows)
        (
          l10n.networkRecoveryTitle,
          l10n.networkRecoverySubtitle,
          AppGlyphs.settings,
          const NetworkDiagnosticsView(kind: NetworkDiagnostic.recovery),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1000
            ? 3
            : constraints.maxWidth >= 620
            ? 2
            : 1;
        final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (title, subtitle, glyph, page) in tools)
              SizedBox(
                width: width,
                child: CommonCard(
                  padding: const EdgeInsets.all(20),
                  onPressed: () => BaseNavigator.push(context, page),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 10,
                    children: [
                      GlyphIcon(
                        glyph,
                        color: context.colorScheme.primary,
                        size: 28,
                      ),
                      Text(title, style: AppTextStyle.headline.of(context)),
                      Text(
                        subtitle,
                        style: AppTextStyle.footnote
                            .of(context)
                            .copyWith(
                              color: context.colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

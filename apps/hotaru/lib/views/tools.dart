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
import 'streaming_test.dart';
import 'network_diagnostics.dart';
import 'node_globe.dart';

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
    return CommonScaffold(
      title: context.appLocalizations.tools,
      body: Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(moreToolsSelectorStateProvider);
          final hasShortcuts = state.navigationItems.isNotEmpty;
          // A section at the top brings its own header padding, which
          // sectionsTopPadding already accounts for; without one the
          // matrix itself must start below the floating title bar, or
          // the first row slides under it.
          return ListView(
            key: toolsStoreKey,
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: hasShortcuts
                  ? context.sectionsTopPadding
                  : context.contentTopPadding,
              bottom: 20 + context.bottomInset,
            ),
            children: [
              if (hasShortcuts) ...[
                generateSection(
                  items: state.navigationItems.map(_buildNavigationMenuItem),
                ),
                const SizedBox(height: 16),
              ],
              _ToolMatrix(
                platform: widget.platform ?? SupportPlatform.currentPlatform,
              ),
            ],
          );
        },
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
        l10n.streamingTestTitle,
        l10n.streamingTestSubtitle,
        AppGlyphs.playPause(0),
        const StreamingTestView(),
      ),
      (
        l10n.speedTest,
        l10n.networkSpeed,
        AppGlyphs.speed,
        const SpeedTestView(),
      ),
      (
        l10n.nodeGlobeTitle,
        l10n.nodeGlobeSubtitle,
        AppGlyphs.pin,
        const NodeGlobeView(),
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
        // Narrow pages read as a list of compact rows; wider ones as a
        // grid of small tiles in the dashboard's card language.
        if (constraints.maxWidth < 620) {
          return Column(
            spacing: 12,
            children: [
              for (final (title, subtitle, glyph, page) in tools)
                _ToolRow(
                  title: title,
                  subtitle: subtitle,
                  glyph: glyph,
                  page: page,
                ),
            ],
          );
        }
        final columns = constraints.maxWidth >= 1100 ? 3 : 2;
        final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (title, subtitle, glyph, page) in tools)
              SizedBox(
                width: width,
                child: _ToolTile(
                  title: title,
                  subtitle: subtitle,
                  glyph: glyph,
                  page: page,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The glyph in its tone tile, shared by the row and tile forms.
class _ToolGlyph extends StatelessWidget {
  const _ToolGlyph({required this.glyph, required this.size});

  final Glyph glyph;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: context.colorScheme.surfaceContainerHigh,
        shape: AppShape.sm,
      ),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: GlyphIcon(
            glyph,
            color: context.colorScheme.primary,
            size: size * 0.55,
          ),
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.title,
    required this.subtitle,
    required this.glyph,
    required this.page,
  });

  final String title;
  final String subtitle;
  final Glyph glyph;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return CommonCard(
      radius: 12,
      padding: const EdgeInsets.all(12),
      onPressed: () => BaseNavigator.push(context, page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          _ToolGlyph(glyph: glyph, size: 36),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.title3.of(context, emphasized: true),
          ),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.title,
    required this.subtitle,
    required this.glyph,
    required this.page,
  });

  final String title;
  final String subtitle;
  final Glyph glyph;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return CommonCard(
      radius: 12,
      padding: const EdgeInsets.all(12),
      onPressed: () => BaseNavigator.push(context, page),
      child: Row(
        spacing: 12,
        children: [
          _ToolGlyph(glyph: glyph, size: 40),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline.of(context, emphasized: true),
                ),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.caption1
                      .of(context)
                      .copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          GlyphIcon(
            AppGlyphs.chevronForward,
            size: 16,
            color: context.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

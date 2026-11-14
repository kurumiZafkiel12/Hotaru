import 'package:hotaru/common/common.dart';
import 'package:hotaru/features/browser_diagnostics/tool_site.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';

import 'embedded_tool.dart';

class IpToolsView extends StatelessWidget {
  const IpToolsView({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return CommonScaffold(
      title: l10n.ipToolsTitle,
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              l10n.ipToolsScope,
              style: AppTextStyle.footnote.of(context),
            ),
          ),
          for (final site in ToolSite.values.where((site) => site.isIpSite))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CommonCard(
                onPressed: () =>
                    BaseNavigator.push(context, EmbeddedToolView(site: site)),
                child: ListTile(
                  title: Text(site.label),
                  subtitle: Text(switch (site) {
                    ToolSite.ipPure ||
                    ToolSite.ping0 ||
                    ToolSite.scamalytics => l10n.ipToolsReputation,
                    ToolSite.browserLeaksIp ||
                    ToolSite.whoer => l10n.ipToolsPrivacy,
                    _ => l10n.ipToolsDetails,
                  }),
                  trailing: const GlyphIcon(AppGlyphs.chevronForward),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

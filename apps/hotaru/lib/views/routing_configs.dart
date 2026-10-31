import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/features/form/form.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

class RoutingConfigsView extends ConsumerWidget {
  const RoutingConfigsView({super.key});

  Future<void> _perform(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (_) {
      if (context.mounted) {
        dialogs.showNotifier(
          context.appLocalizations.routingConfigFailed,
          level: MessageLevel.error,
        );
      }
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final l10n = context.appLocalizations;
    final links = await showNamedUrlsForm(
      context,
      title: l10n.routingConfigImport,
      urlLabel: l10n.link,
      existingUrls: {
        for (final config in ref.read(appSettingProvider).routingConfigs)
          config.url,
      },
      urlValidator: (value) {
        final uri = Uri.tryParse(value ?? '');
        return uri != null &&
                const ['http', 'https'].contains(uri.scheme) &&
                uri.host.isNotEmpty
            ? null
            : l10n.invalidLinkTip;
      },
    );
    if (links == null || !context.mounted) return;
    await _perform(context, () async {
      for (final link in links) {
        await ref
            .read(routingConfigsActionProvider.notifier)
            .importLink(link.url, name: link.label);
      }
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.appLocalizations;
    final settings = ref.watch(appSettingProvider);
    final busy = ref.watch(routingConfigsActionProvider);
    final action = ref.read(routingConfigsActionProvider.notifier);
    return CommonScaffold(
      title: l10n.routingConfigs,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.add,
          tooltip: l10n.routingConfigImport,
          onPressed: busy ? null : () => _import(context, ref),
        ),
      ],
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          14,
          context.contentTopPadding,
          14,
          24 + context.bottomInset,
        ),
        children: [
          Text(
            l10n.routingConfigHint,
            style: AppTextStyle.footnote.of(context),
          ),
          const SizedBox(height: 12),
          if (busy) const LinearProgressIndicator(),
          if (settings.routingConfigs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(l10n.routingConfigEmpty),
            ),
          for (final config in settings.routingConfigs)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: CommonCard(
                onPressed: busy
                    ? null
                    : () => _perform(context, () => action.select(config.id)),
                padding: const EdgeInsets.all(12),
                child: Row(
                  spacing: 12,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          Text(
                            config.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.subheadline.of(
                              context,
                              emphasized: true,
                            ),
                          ),
                          Text(
                            '${config.ruleCount} ${l10n.rules} · ${DateFormat.yMd().add_Hm().format(config.updatedAt.toLocal())}',
                            style: AppTextStyle.caption1.of(context),
                          ),
                        ],
                      ),
                    ),
                    if (settings.activeRoutingConfigId == config.id)
                      const GlyphIcon(AppGlyphs.check),
                    IconButton(
                      tooltip: l10n.update,
                      onPressed: busy
                          ? null
                          : () =>
                                _perform(context, () => action.update(config)),
                      icon: const GlyphIcon(AppGlyphs.refresh),
                    ),
                    IconButton(
                      tooltip: l10n.delete,
                      onPressed: busy
                          ? null
                          : () async {
                              final confirmed = await dialogs.showMessage(
                                message: TextSpan(
                                  text: l10n.deleteTip(l10n.routingConfigs),
                                ),
                              );
                              if (confirmed == true && context.mounted) {
                                await _perform(
                                  context,
                                  () => action.remove(config),
                                );
                              }
                            },
                      icon: const GlyphIcon(AppGlyphs.delete),
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

import 'package:hotaru/common/common.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/views/about.dart';
import 'package:hotaru/views/access.dart';
import 'package:hotaru/views/backup_and_restore.dart';
import 'package:hotaru/views/config/general.dart';
import 'package:hotaru/views/hotkey.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config/advanced.dart';
import 'config/custom_resources.dart';
import 'developer.dart';
import 'theme.dart';

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final developerMode = ref.watch(
      appSettingProvider.select((state) => state.developerMode),
    );
    return CommonScaffold(
      title: appLocalizations.settings,
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: appLocalizations.settings,
            items: [
              const _LocaleItem(),
              const _ThemeItem(),
              const _BackupItem(),
              if (system.isDesktop) const _HotkeyItem(),
              if (system.isAndroid) const _AccessItem(),
              const _AdvancedConfigItem(),
              const _CustomResourcesItem(),
              const _GeneralItem(),
            ],
            footer: [
              if (system.isAndroid) appLocalizations.accessControlDesc,
              appLocalizations.advancedConfigDesc,
              appLocalizations.customProfileResourcesDesc,
            ].join('\n'),
          ),
          generateSection(
            title: appLocalizations.other,
            items: [
              if (developerMode) const _DeveloperItem(),
              const _InfoItem(),
            ],
          ),
        ],
      ),
    );
  }
}

class _LocaleItem extends ConsumerWidget {
  const _LocaleItem();

  String _getLocaleString(BuildContext context, Locale? locale) {
    if (locale == null) return context.appLocalizations.defaultText;
    return locale.label;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(
      appSettingProvider.select((state) => state.locale),
    );
    final currentLocale = getLocaleForString(locale);
    return ListItem<Locale?>.options(
      leading: const GlyphIcon(AppGlyphs.language),
      title: Text(context.appLocalizations.language),
      options: [null, ...AppLocalizations.delegate.supportedLocales],
      onChanged: (Locale? locale) {
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(locale: locale?.toString()));
      },
      textBuilder: (locale) => _getLocaleString(context, locale),
      value: currentLocale,
    );
  }
}

class _ThemeItem extends StatelessWidget {
  const _ThemeItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.paintbrush),
      title: Text(context.appLocalizations.theme),
      widget: const ThemeView(),
    );
  }
}

class _BackupItem extends StatelessWidget {
  const _BackupItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.cloudSync),
      title: Text(context.appLocalizations.backupAndRestore),
      widget: const BackupAndRestore(),
    );
  }
}

class _HotkeyItem extends StatelessWidget {
  const _HotkeyItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.keyboard),
      title: Text(context.appLocalizations.hotkeyManagement),
      widget: const HotKeyView(),
    );
  }
}

class _AccessItem extends StatelessWidget {
  const _AccessItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.appsList),
      title: Text(context.appLocalizations.accessControl),
      widget: const AccessView(),
    );
  }
}

class _GeneralItem extends StatelessWidget {
  const _GeneralItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.settings),
      title: Text(context.appLocalizations.general),
      widget: const GeneralView(),
    );
  }
}

class _AdvancedConfigItem extends StatelessWidget {
  const _AdvancedConfigItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.wrench),
      title: Text(context.appLocalizations.advancedConfig),
      widget: const AdvancedConfigView(),
    );
  }
}

class _CustomResourcesItem extends StatelessWidget {
  const _CustomResourcesItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.customize),
      title: Text(context.appLocalizations.customProfileResources),
      widget: const CustomResourcesView(),
    );
  }
}

class _InfoItem extends StatelessWidget {
  const _InfoItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.info),
      title: Text(context.appLocalizations.about),
      widget: const AboutView(),
    );
  }
}

class _DeveloperItem extends StatelessWidget {
  const _DeveloperItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.cpu),
      title: Text(context.appLocalizations.developerMode),
      widget: const DeveloperView(),
    );
  }
}

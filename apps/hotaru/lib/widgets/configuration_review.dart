import 'dart:isolate';

import 'package:material_ui/material_ui.dart';

import '../common/context.dart';
import '../core/config/profile.dart';
import '../l10n/l10n.dart';
import '../ui/ui.dart';
import '../ui/icons/icons.dart';

final class ConfigurationReviewGroup {
  final String code;
  final CoreConfigIssueSeverity severity;
  final int count;
  final List<String> paths;

  ConfigurationReviewGroup(
    this.code,
    this.severity,
    this.count,
    List<String> paths,
  ) : paths = List.unmodifiable(paths);
}

final class ConfigurationReviewData {
  final int errors;
  final int warnings;
  final List<ConfigurationReviewGroup> groups;

  ConfigurationReviewData._(
    this.errors,
    this.warnings,
    List<ConfigurationReviewGroup> groups,
  ) : groups = List.unmodifiable(groups);

  static Future<ConfigurationReviewData> prepare(
    List<CoreConfigIssue> issues,
  ) => Isolate.run(() {
    final counts = <(String, CoreConfigIssueSeverity), int>{};
    final paths = <(String, CoreConfigIssueSeverity), Set<String>>{};
    var errors = 0;
    var warnings = 0;
    final validCode = RegExp(r'^[a-z0-9_]{1,80}$');
    for (final issue in issues) {
      if (issue.severity == CoreConfigIssueSeverity.error) {
        errors++;
      } else {
        warnings++;
      }
      var key = (
        validCode.hasMatch(issue.code) ? issue.code : 'other',
        issue.severity,
      );
      if (!counts.containsKey(key) && counts.length >= 32) {
        key = ('other', issue.severity);
      }
      counts.update(key, (count) => count + 1, ifAbsent: () => 1);
      final examples = paths.putIfAbsent(key, () => {});
      if (examples.length < 3) {
        examples.add(
          String.fromCharCodes(
            issue.path.runes
                .take(180)
                .map((rune) => rune < 32 || rune == 127 ? 32 : rune),
          ),
        );
      }
    }
    final groups = [
      for (final severity in [
        CoreConfigIssueSeverity.error,
        CoreConfigIssueSeverity.warning,
      ])
        for (final entry in counts.entries)
          if (entry.key.$2 == severity)
            ConfigurationReviewGroup(
              entry.key.$1,
              severity,
              entry.value,
              paths[entry.key]!.toList(),
            ),
    ];
    return ConfigurationReviewData._(errors, warnings, groups);
  });
}

class ConfigurationReviewDialog extends StatelessWidget {
  final ConfigurationReviewData data;

  const ConfigurationReviewDialog({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final canApply = data.errors == 0;
    return CommonDialog(
      title: l10n.configurationReviewTitle,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(canApply ? l10n.cancel : l10n.close),
        ),
        if (canApply)
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.configurationReviewApply),
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text(
            canApply
                ? l10n.configurationReviewIntro
                : l10n.configurationReviewBlocked,
          ),
          Text(
            l10n.configurationReviewSummary(data.errors, data.warnings),
            style: AppTextStyle.subheadline.of(context, emphasized: true),
          ),
          for (final group in data.groups)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(_description(l10n, group)),
                Text(
                  l10n.configurationReviewCount(group.count),
                  style: AppTextStyle.caption1.of(context),
                ),
                _ReviewLocations(group: group),
              ],
            ),
        ],
      ),
    );
  }

  static String _description(
    AppLocalizations l10n,
    ConfigurationReviewGroup group,
  ) => switch (group.code) {
    'app_owned_setting_replaced' ||
    'provider_cache_path_client_owned' => l10n.configurationReviewOwned,
    'metadata_field_ignored' => l10n.configurationReviewMetadata,
    'ip_resolution_semantics_changed' => l10n.configurationReviewIpRules,
    'geoip_database_changed' => l10n.configurationReviewGeo,
    'dns_hosts_not_migrated' ||
    'dns_system_hosts_not_migrated' => l10n.configurationReviewHosts,
    'load_balance_to_selector' => l10n.configurationReviewLoadBalance,
    'fallback_to_urltest' => l10n.configurationReviewFallback,
    'provider_health_check_not_migrated' => l10n.configurationReviewHealth,
    'duplicate_group_member_collapsed' => l10n.configurationReviewDuplicates,
    _ =>
      group.severity == CoreConfigIssueSeverity.error
          ? l10n.configurationReviewUnsupported
          : l10n.configurationReviewChanged,
  };
}

class _ReviewLocations extends StatefulWidget {
  final ConfigurationReviewGroup group;

  const _ReviewLocations({required this.group});

  @override
  State<_ReviewLocations> createState() => _ReviewLocationsState();
}

class _ReviewLocationsState extends State<_ReviewLocations> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final group = widget.group;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      onExpansionChanged: (value) => setState(() => _expanded = value),
      trailing: GlyphIcon(
        _expanded ? AppGlyphs.chevronUp : AppGlyphs.chevronDown,
      ),
      title: Text(
        l10n.configurationReviewLocations,
        style: AppTextStyle.caption1.of(context),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            [
              group.code,
              ...group.paths,
              if (group.count > group.paths.length)
                l10n.configurationReviewMore(group.count - group.paths.length),
            ].join('\n'),
            style: AppTextStyle.caption1.of(context),
          ),
        ),
      ],
    );
  }
}

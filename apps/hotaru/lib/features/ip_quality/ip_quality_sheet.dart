import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/ip_quality.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/config.dart';
import 'package:hotaru/providers/ip_quality.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'ip_quality_text.dart';
import 'labels.dart';
import 'facts_labels.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/ip_facts.dart';
import 'package:hotaru/providers/ip_facts.dart';

Future<void> showIpQualitySheet(
  BuildContext context, {
  required String ip,
  SupportPlatform? platform,
}) {
  Widget sheet() =>
      (platform ?? SupportPlatform.currentPlatform) == SupportPlatform.Windows
      ? IpFactsSheet(ip: ip)
      : _IpQualitySheet(ip: ip);
  if (isSheetPage(context)) {
    return Navigator.of(context).push(PagedSheetRoute(builder: (_) => sheet()));
  }
  return showSheet<void>(context: context, builder: (_) => sheet());
}

class _IpQualitySheet extends ConsumerWidget {
  const _IpQualitySheet({required this.ip});

  final String ip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localizations = context.appLocalizations;
    final isLoading = ref.watch(
      ipQualityProvider(ip).select((result) => result.isLoading),
    );
    return CommonScaffold(
      title: localizations.outboundIp,
      actions: [
        AppBarActionButton(
          data: IconButtonData(
            glyph: AppGlyphs.refresh,
            tooltip: localizations.ipQualityRetry,
            isLoading: isLoading,
            onPressed: () => ref.invalidate(ipQualityProvider(ip)),
          ),
        ),
      ],
      body: _IpQualityDetail(ip: ip),
    );
  }
}

class _HideIpItem extends ConsumerWidget {
  const _HideIpItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hideIp = ref.watch(
      appSettingProvider.select((state) => state.hideIp),
    );
    void update(bool value) => ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(hideIp: value));
    return DecorationListItem(
      title: Text(context.appLocalizations.hideIp),
      onPressed: () => update(!hideIp),
      trailing: CommonSwitch(value: hideIp, onChanged: update),
    );
  }
}

class _IpQualityDetail extends ConsumerWidget {
  const _IpQualityDetail({required this.ip});

  /// The optical edge of the xl-radius cards, as in the memory sheet.
  static const _tipInset = 5.0;

  final String ip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localizations = context.appLocalizations;
    final result = ref.watch(ipQualityProvider(ip));
    final quality = result.value;
    final error = result.error;
    final failed = quality == null && !result.isLoading;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
        bottom: 20 + context.bottomInset,
        top: context.contentTopPadding,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(_tipInset, 8, _tipInset, 0),
          child: Text(
            localizations.detectionTip,
            style: AppTextStyle.body
                .of(context)
                .copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ),
        generateSection(
          title: localizations.basicInfo,
          items: [
            DetailRow(
              title: localizations.ipAddress,
              copyText: ip,
              value: IpQualityText(ip: ip),
            ),
            if (failed)
              DetailRow(
                title: localizations.ipType,
                value: Text(
                  localizations.ipQualityFailed,
                  style: TextStyle(color: context.colorScheme.error),
                ),
              )
            else
              ..._qualityRows(context, quality),
          ],
        ),
        if (!failed)
          generateSection(
            title: localizations.network,
            items: _networkRows(context, quality),
          ),
        if (failed && error is IpQualityLookupException)
          generateSection(
            title: localizations.ipQualitySources,
            items: [
              for (final failure in error.failures)
                DetailRow(
                  title: failure.source.label,
                  value: Text(failure.status.label(context)),
                ),
            ],
          ),
        generateSection(
          title: localizations.other,
          items: const [_HideIpItem()],
        ),
      ],
    );
  }

  /// A lookup still running lays out every row it will fill, so the page
  /// keeps its height when the values arrive.
  List<Widget> _qualityRows(BuildContext context, IpQuality? quality) {
    final localizations = context.appLocalizations;
    if (quality == null) {
      return [
        DetailRow(
          title: localizations.ipQualityLevel,
          value: const SkeletonText(width: 40),
        ),
        DetailRow(
          title: localizations.ipType,
          value: const SkeletonText(width: 64),
        ),
        DetailRow(
          title: localizations.ipFlags,
          value: const SkeletonText(width: 40),
        ),
      ];
    }
    final flags = [
      if (quality.isTor) localizations.ipFlagTor,
      if (quality.isAbuser) localizations.ipFlagAbuser,
      if (quality.isVpn) localizations.ipFlagVpn,
      if (quality.isProxy) localizations.ipFlagProxy,
    ];
    return [
      DetailRow(
        title: localizations.ipQualityLevel,
        value: Text(
          quality.level.label(context),
          style: TextStyle(color: quality.level.color(context)),
        ),
      ),
      DetailRow(
        title: localizations.ipType,
        value: Text(quality.type.label(context)),
      ),
      DetailRow(
        title: localizations.ipFlags,
        value: flags.isEmpty
            ? Text(localizations.none)
            : Wrap(
                spacing: 6,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [for (final flag in flags) MetaChip(label: flag)],
              ),
      ),
    ];
  }

  List<Widget> _networkRows(BuildContext context, IpQuality? quality) {
    final localizations = context.appLocalizations;
    Widget valueOf(String? text, {required double width}) =>
        switch ((quality, text)) {
          (null, _) => SkeletonText(width: width),
          (_, final text?) => Text(text),
          _ => const Text('—'),
        };
    final organization = quality?.organization;
    final asn = switch (quality?.asn) {
      final asn? => 'AS$asn',
      null => null,
    };
    return [
      DetailRow(
        title: localizations.ipOrganization,
        copyText: organization,
        value: valueOf(organization, width: 120),
      ),
      DetailRow(
        title: localizations.ipAsn,
        copyText: asn,
        value: valueOf(asn, width: 56),
      ),
      DetailRow(
        title: localizations.ipQualitySource,
        value: valueOf(quality?.source.label, width: 72),
      ),
    ];
  }
}

class IpFactsSheet extends ConsumerWidget {
  const IpFactsSheet({super.key, required this.ip});
  final String ip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.appLocalizations;
    final state = ref.watch(ipFactsProvider(ip));
    final facts = state.value;
    Widget value(String text) => state.isLoading && facts == null
        ? const SkeletonText(width: 64)
        : Text(text);
    return CommonScaffold(
      title: l10n.outboundIp,
      actions: [
        AppBarActionButton(
          data: IconButtonData(
            glyph: AppGlyphs.refresh,
            tooltip: l10n.ipQualityRetry,
            isLoading: state.isLoading,
            onPressed: () => ref.invalidate(ipFactsProvider(ip)),
          ),
        ),
      ],
      body: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.contentTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: l10n.basicInfo,
            items: [
              DetailRow(
                title: l10n.ipAddress,
                copyText: ip,
                value: IpQualityText(ip: ip, useIpFacts: true),
              ),
              DetailRow(
                title: l10n.ipFactsOrigin,
                value: Tooltip(
                  message: facts?.originEvidence(context) ?? l10n.ipFactsScope,
                  child: value(
                    (facts?.origin ?? IpOrigin.unknown).label(context),
                  ),
                ),
              ),
              DetailRow(
                title: l10n.ipFactsAttribute,
                value: value(
                  (facts?.attribute ?? IpAttribute.unknown).label(context),
                ),
              ),
              DetailRow(
                title: l10n.ipFactsQuality,
                value: state.isLoading && facts == null
                    ? const SkeletonText(width: 120)
                    : Text(
                        facts?.qualityLabel(context) ?? l10n.unknown,
                        style: TextStyle(color: facts?.risk.color(context)),
                      ),
              ),
            ],
          ),
          generateSection(
            title: l10n.network,
            items: [
              DetailRow(
                title: l10n.ipOrganization,
                copyText: facts?.organization,
                value: value(facts?.organization ?? l10n.unknown),
              ),
              DetailRow(
                title: l10n.ipAsn,
                copyText: facts?.asn == null ? null : 'AS${facts!.asn}',
                value: value(
                  facts?.asn == null ? l10n.unknown : 'AS${facts!.asn}',
                ),
              ),
              DetailRow(
                title: l10n.ipQualitySource,
                value: const Text('iplocate · RDAP · Scamalytics'),
              ),
            ],
          ),
          generateSection(title: l10n.other, items: const [_HideIpItem()]),
          Padding(
            padding: const EdgeInsets.fromLTRB(5, 8, 5, 0),
            child: Text(
              l10n.ipFactsScope,
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

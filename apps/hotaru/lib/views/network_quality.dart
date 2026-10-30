import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/network_quality.dart';
import 'package:hotaru/providers/network_quality.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

Future<void> showNetworkQualitySheet(BuildContext context) {
  if (isSheetPage(context)) {
    return Navigator.of(
      context,
    ).push(PagedSheetRoute(builder: (_) => const NetworkQualityView()));
  }
  return showSheet<void>(
    context: context,
    builder: (_) => const NetworkQualityView(),
  );
}

class NetworkQualityView extends ConsumerStatefulWidget {
  const NetworkQualityView({super.key});

  @override
  ConsumerState<NetworkQualityView> createState() => _NetworkQualityViewState();
}

class _NetworkQualityViewState extends ConsumerState<NetworkQualityView> {
  late final NetworkQuality _measurement;
  late final RouteTracker _tracker;

  @override
  void initState() {
    super.initState();
    _measurement = ref.read(networkQualityProvider.notifier);
    _tracker = ref.read(routeTrackerProvider.notifier);
    _tracker.attach();
  }

  @override
  void dispose() {
    _measurement.stop();
    _tracker.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final state = ref.watch(networkQualityProvider);
    final report = state.reportFor(ref.watch(routeTrackerProvider));
    final ready =
        ref.watch(isStartProvider) &&
        !ref.watch(suspendProvider) &&
        ref.watch(
          routeTrackerProvider.select(
            (route) => route.live && route.synced && route.proxied,
          ),
        );
    String milliseconds(double? value) =>
        value == null ? l10n.unknown : '${value.toStringAsFixed(1)} ms';
    return CommonScaffold(
      title: l10n.statusNetworkQuality,
      body: ListView(
        controller: sheetScrollController(context),
        padding: EdgeInsets.fromLTRB(
          16,
          context.appBarInset,
          16,
          24 + context.bottomInset,
        ),
        children: [
          Text(l10n.qualityScope, style: AppTextStyle.footnote.of(context)),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: !ready
                  ? null
                  : state.running
                  ? _measurement.cancel
                  : _measurement.measure,
              child: Text(
                state.running
                    ? '${l10n.cancel} · ${state.progress}/$networkQualityRounds'
                    : l10n.start,
              ),
            ),
          ),
          if (!ready)
            Text(
              l10n.diagnosticsNeedCore,
              style: AppTextStyle.footnote.of(context),
            ),
          if (state.running)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(
                value: state.progress / networkQualityRounds,
              ),
            ),
          const SizedBox(height: 12),
          CommonCard(
            padding: const EdgeInsets.all(14),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(
                    (report?.grade ?? NetworkQualityGrade.unknown).label,
                    style: AppTextStyle.title3.of(context, emphasized: true),
                  ),
                  if (report?.grade == NetworkQualityGrade.unknown)
                    Text(
                      report!.chains.isNotEmpty && !report.stableRoute
                          ? l10n.auditStale
                          : l10n.diagnosticsInsufficient,
                      style: AppTextStyle.footnote.of(context),
                    ),
                  Text(
                    '${l10n.qualityMedian}: ${milliseconds(report?.medianMs)}',
                    style: AppTextStyle.body.of(context),
                  ),
                  Text(
                    '${l10n.speedTestJitter}: ${milliseconds(report?.jitterMs)}',
                    style: AppTextStyle.body.of(context),
                  ),
                  Text(
                    '${l10n.qualityFailureRate}: ${report == null ? l10n.unknown : '${(report.failureRate * 100).toStringAsFixed(0)}% (${report.samples.length - report.completed}/${report.samples.length})'}',
                    style: AppTextStyle.body.of(context),
                  ),
                  Text(
                    l10n.qualityExpiry,
                    style: AppTextStyle.footnote.of(context),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.qualityThresholds,
            style: AppTextStyle.footnote.of(context),
          ),
          const SizedBox(height: 12),
          Text(
            networkQualityUrl,
            style: AppTextStyle.footnote.of(context).toJetBrainsMono,
          ),
          if (report != null) ...[
            Text(
              report.chains.reversed.join(' ➜ '),
              style: AppTextStyle.footnote.of(context),
            ),
            ExpansionTile(
              title: Text(
                l10n.diagnosticsRawEvidence,
                style: AppTextStyle.body.of(context),
              ),
              shape: AppShape.md,
              collapsedShape: AppShape.md,
              children: [
                for (final (index, sample) in report.samples.indexed)
                  Text(
                    '${index + 1}. HTTP ${sample?.statusCode ?? 0} · ${sample?.delay ?? 0} ms · ${sample?.error ?? ''}\n${sample?.chains.reversed.join(" ➜ ") ?? l10n.unknown}\n${sample?.rule ?? ""}, ${sample?.rulePayload ?? ""}',
                    style: AppTextStyle.footnote.of(context).toJetBrainsMono,
                  ),
                Text(
                  '${report.checkedAt.toLocal()}',
                  style: AppTextStyle.footnote.of(context),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

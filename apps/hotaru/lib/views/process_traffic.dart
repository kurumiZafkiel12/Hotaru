import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/features/process_traffic/ranking.dart';
import 'package:hotaru/providers/core.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

class ProcessTrafficView extends ConsumerStatefulWidget {
  const ProcessTrafficView({super.key});

  @override
  ConsumerState<ProcessTrafficView> createState() => _ProcessTrafficViewState();
}

class _ProcessTrafficViewState extends ConsumerState<ProcessTrafficView>
    with
        WidgetsBindingObserver,
        ActivePollingMixin<ProcessTrafficView>,
        RouteMotionHoldMixin<ProcessTrafficView> {
  CoreProcessTraffic? _raw;
  List<ProcessTrafficRow> _rows = const [];
  ProcessTrafficGrouping _grouping = ProcessTrafficGrouping.application;
  var _loaded = false;
  var _failed = false;
  var _unavailable = false;
  var _rankingRevision = 0;

  @override
  Duration get pollInterval => const Duration(seconds: 2);

  @override
  Future<void> poll(PollGuard isCurrent) async {
    final revision = ++_rankingRevision;
    final core = ref.read(coreHandlerProvider);
    try {
      final raw = core.supportsProcessTraffic
          ? await core.getProcessTraffic()
          : null;
      if (!isCurrent() || revision != _rankingRevision) return;
      final rows = raw == null
          ? const <ProcessTrafficRow>[]
          : await rankProcessTraffic(raw, _grouping);
      if (!isCurrent() || revision != _rankingRevision) return;
      void apply() {
        if (!isCurrent() || revision != _rankingRevision) return;
        setState(() {
          _raw = raw;
          _rows = rows;
          _loaded = true;
          _failed = false;
          _unavailable = raw == null;
        });
      }

      if (!_loaded) {
        apply();
      } else {
        updateWhenRouteSettled(apply);
      }
    } catch (_) {
      if (!isCurrent() || revision != _rankingRevision) return;
      setState(() {
        _loaded = true;
        _failed = true;
        _unavailable = false;
        _raw = null;
        _rows = const [];
      });
    }
  }

  void _setGrouping(Set<ProcessTrafficGrouping> selected) {
    final next = selected.single;
    if (next == _grouping) return;
    setState(() => _grouping = next);
    restartPolling();
  }

  @override
  void dispose() {
    _rankingRevision++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final raw = _raw;
    final unknown =
        (raw?.unattributedUpload ?? 0) + (raw?.unattributedDownload ?? 0);
    return CommonScaffold(
      title: l10n.processTrafficTitle,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: l10n.update,
          onPressed: restartPolling,
        ),
      ],
      body: NullStatusSwitcher(
        isLoading: !_loaded,
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: 1 + _rows.length + (unknown > 0 ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    Text(
                      l10n.processTrafficScope,
                      style: AppTextStyle.footnote.of(context),
                    ),
                    SegmentedButton<ProcessTrafficGrouping>(
                      segments: [
                        ButtonSegment(
                          value: ProcessTrafficGrouping.application,
                          label: Text(l10n.processTrafficByApp),
                        ),
                        ButtonSegment(
                          value: ProcessTrafficGrouping.process,
                          label: Text(l10n.processTrafficByProcess),
                        ),
                      ],
                      selected: {_grouping},
                      onSelectionChanged: _setGrouping,
                    ),
                    if (_unavailable) Text(l10n.processTrafficUnavailable),
                    if (_failed) Text(l10n.processTrafficFailed),
                    if (_loaded &&
                        !_unavailable &&
                        !_failed &&
                        _rows.isEmpty &&
                        unknown == 0)
                      Text(l10n.processTrafficEmpty),
                    if (raw?.overflow == true)
                      Text(l10n.processTrafficOverflow),
                    if (raw?.sampledAt != null)
                      Text(
                        '${l10n.processTrafficSampled}: ${raw!.sampledAt!.toLocal().showFull}',
                        style: AppTextStyle.footnote.of(context),
                      ),
                  ],
                ),
              );
            }
            final isUnknown = index > _rows.length;
            final row = isUnknown ? null : _rows[index - 1];
            final path = row?.path ?? '';
            final name = path.isNotEmpty
                ? path.split(RegExp(r'[/\\]')).last
                : l10n.processTrafficUnattributed;
            final upload = row?.upload ?? raw!.unattributedUpload;
            final download = row?.download ?? raw!.unattributedDownload;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CommonCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  spacing: 12,
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: path.isEmpty ? name : path,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 4,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyle.headline.of(context),
                            ),
                            if (row?.pids.isNotEmpty == true)
                              Text(
                                'PID ${row!.pids.join(', ')}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyle.footnote.of(context),
                              ),
                            Text(
                              '↑ ${upload.traffic.show} · ↓ ${download.traffic.show}',
                              style: AppTextStyle.footnote.of(context),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Text(
                      (upload + download).traffic.show,
                      style: AppTextStyle.headline.of(context),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

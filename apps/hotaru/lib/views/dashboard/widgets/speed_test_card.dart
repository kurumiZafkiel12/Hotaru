import 'package:hotaru/common/common.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/views/speed_test.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'card.dart';

/// Home shortcut for the toolbox speed test: runs a short download check
/// on the current route inline, and opens the full page on tap.
class SpeedTestShortcutCard extends ConsumerStatefulWidget {
  const SpeedTestShortcutCard({super.key});

  @override
  ConsumerState<SpeedTestShortcutCard> createState() =>
      _SpeedTestShortcutCardState();
}

class _SpeedTestShortcutCardState extends ConsumerState<SpeedTestShortcutCard> {
  bool _running = false;
  double _liveBps = 0;
  double? _downloadBps;
  String? _error;
  SpeedTestRunner? _runner;

  @override
  void dispose() {
    _runner?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_running) {
      _runner?.cancel();
      return;
    }
    final proxy = HotaruHttpOverrides.findProxyForReader(
      ref.read,
      Uri.parse('https://example.com'),
    );
    final runner = SpeedTestRunner(findProxy: (_) => proxy);
    _runner = runner;
    setState(() {
      _running = true;
      _liveBps = 0;
      _error = null;
    });
    final result = await runner.run(
      provider: SpeedTestProvider.apple,
      durationSeconds: 10,
      downloadOnly: true,
      onProgress: (phase, liveBps, _) {
        if (!mounted || phase != SpeedTestPhase.download) {
          return;
        }
        setState(() {
          _liveBps = liveBps;
        });
      },
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _running = false;
      if (result.error != null) {
        _error = result.error;
      } else if (!result.cancelled) {
        _downloadBps = result.downloadBps;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final value = _error != null
        ? appLocalizations.error
        : _running
        ? '${formatSpeedValue(_liveBps)} ${formatSpeedUnit(_liveBps)}'
        : _downloadBps == null
        ? appLocalizations.unknown
        : '${formatSpeedValue(_downloadBps!)} ${formatSpeedUnit(_downloadBps!)}';
    return DashboardCard(
      onTap: () => BaseNavigator.push(context, const SpeedTestView()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            spacing: 8,
            children: [
              GlyphIcon(
                AppGlyphs.speed,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              Text(
                appLocalizations.speedTest,
                style: AppTextStyle.subheadline.of(context, emphasized: true),
              ),
              const Spacer(),
              IconButton(
                tooltip: _running
                    ? appLocalizations.stop
                    : appLocalizations.start,
                onPressed: _toggle,
                icon: GlyphIcon(
                  AppGlyphs.playPause(_running ? 1 : 0),
                  size: 18,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            value,
            style: AppTextStyle.title2.of(context, emphasized: true),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            appLocalizations.download,
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

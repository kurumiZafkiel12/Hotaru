import 'package:hotaru/common/common.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SpeedTestView extends ConsumerStatefulWidget {
  const SpeedTestView({super.key});

  @override
  ConsumerState<SpeedTestView> createState() => _SpeedTestViewState();
}

class _SpeedTestViewState extends ConsumerState<SpeedTestView> {
  static const _durations = [5, 10, 15, 20];

  SpeedTestProvider _provider = SpeedTestProvider.apple;
  int _duration = 10;
  SpeedTestPhase? _phase;
  double _liveBps = 0;
  double _progress = 0;
  double? _latencyMs;
  double? _downloadBps;
  double? _uploadBps;
  String _serverLabel = '';
  String? _error;
  bool _running = false;
  bool _routed = false;
  SpeedTestRunner? _runner;

  @override
  void dispose() {
    _runner?.cancel();
    super.dispose();
  }

  String _phaseLabel(SpeedTestPhase? phase) {
    final appLocalizations = context.appLocalizations;
    return switch (phase) {
      null => appLocalizations.notRunning,
      SpeedTestPhase.connecting => appLocalizations.connecting,
      SpeedTestPhase.latency => appLocalizations.delay,
      SpeedTestPhase.download => appLocalizations.download,
      SpeedTestPhase.upload => appLocalizations.upload,
      SpeedTestPhase.done => appLocalizations.result,
    };
  }

  String _speedText(double? bps) {
    if (bps == null) {
      return context.appLocalizations.unknown;
    }
    return '${formatSpeedValue(bps)} ${formatSpeedUnit(bps)}';
  }

  String _latencyText(double? ms) {
    if (ms == null) {
      return context.appLocalizations.unknown;
    }
    return '${ms.round()} ms';
  }

  Future<void> _start() async {
    if (_running) {
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
      _phase = SpeedTestPhase.connecting;
      _liveBps = 0;
      _progress = 0;
      _error = null;
      _latencyMs = null;
      _downloadBps = null;
      _uploadBps = null;
      _serverLabel = '';
      _routed = proxy.startsWith('PROXY');
    });
    final result = await runner.run(
      provider: _provider,
      durationSeconds: _duration,
      onProgress: (phase, liveBps, progress) {
        if (!mounted) {
          return;
        }
        setState(() {
          _phase = phase;
          _liveBps = liveBps;
          _progress = progress;
        });
      },
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _running = false;
      if (result.cancelled) {
        _phase = null;
      } else if (result.error != null) {
        _phase = SpeedTestPhase.done;
        _error = result.error;
      } else {
        _phase = SpeedTestPhase.done;
        _latencyMs = result.latencyMs;
        _downloadBps = result.downloadBps;
        _uploadBps = result.uploadBps;
        _serverLabel = result.serverLabel;
      }
    });
  }

  void _stop() {
    _runner?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final liveText = _running
        ? _speedText(_liveBps)
        : _serverLabel.isEmpty
        ? appLocalizations.speedTestNotRun
        : _speedText(_downloadBps);
    return BaseScaffold(
      title: appLocalizations.speedTest,
      body: ListView(
        padding: EdgeInsets.only(
          top: context.appBarInset,
          bottom: 32 + context.bottomInset,
          left: 16,
          right: 16,
        ),
        children: [
          generateSection(
            items: [
              ListItem<SpeedTestProvider>.options(
                leading: const GlyphIcon(AppGlyphs.speed),
                title: Text(appLocalizations.speedTestProvider),
                options: SpeedTestProvider.values,
                value: _provider,
                textBuilder: (provider) => provider.label,
                onChanged: (provider) {
                  if (!_running) {
                    setState(() {
                      _provider = provider;
                    });
                  }
                },
              ),
              ListItem<int>.options(
                leading: const GlyphIcon(AppGlyphs.clock),
                title: Text(appLocalizations.duration),
                options: _durations,
                value: _duration,
                textBuilder: (duration) =>
                    '$duration ${appLocalizations.seconds}',
                onChanged: (duration) {
                  if (!_running) {
                    setState(() {
                      _duration = duration;
                    });
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            liveText,
            style: AppTextStyle.display.of(context, emphasized: true),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            _phaseLabel(_phase),
            style: AppTextStyle.subheadline.of(context),
            textAlign: TextAlign.center,
          ),
          if (_running) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress.clamp(0, 1)),
          ],
          const SizedBox(height: 16),
          generateSection(
            items: [
              ListItem(
                title: Text(appLocalizations.delay),
                trailing: Text(_latencyText(_latencyMs)),
              ),
              ListItem(
                title: Text(appLocalizations.download),
                trailing: Text(_speedText(_downloadBps)),
              ),
              ListItem(
                title: Text(appLocalizations.upload),
                trailing: Text(_speedText(_uploadBps)),
              ),
              ListItem(
                title: Text(appLocalizations.server),
                trailing: Text(
                  _serverLabel.isEmpty
                      ? appLocalizations.unknown
                      : _serverLabel,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _running ? _stop : _start,
            child: Text(
              _running ? appLocalizations.stop : appLocalizations.start,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _running || _serverLabel.isEmpty
                ? ''
                : _routed
                ? appLocalizations.speedTestViaProxy
                : appLocalizations.speedTestDirect,
            style: AppTextStyle.footnote.of(context),
            textAlign: TextAlign.center,
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              '${appLocalizations.error}: $_error',
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

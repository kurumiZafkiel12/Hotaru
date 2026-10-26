import 'dart:math' as math;

import 'package:hotaru/common/common.dart';
import 'package:hotaru/providers/providers.dart';
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
  double? _latencyMs;
  double? _jitterMs;
  double? _downloadBps;
  double? _uploadBps;
  bool _uploadUnsupported = false;
  String _serverLabel = '';
  String _exitNode = '';
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

  double get _gaugeBps {
    if (_running) {
      return switch (_phase) {
        SpeedTestPhase.download || SpeedTestPhase.upload => _liveBps,
        _ => 0,
      };
    }
    return _downloadBps ?? 0;
  }

  Future<void> _start() async {
    if (_running) {
      return;
    }
    final proxy = HotaruHttpOverrides.findProxyForReader(
      ref.read,
      Uri.parse('https://example.com'),
    );
    final routed = proxy.startsWith('PROXY');
    var exitNode = '';
    if (routed) {
      try {
        final data = await ref.read(coreHandlerProvider).getProxies();
        final chain = resolveProxyChain(data.proxies, 'GLOBAL');
        if (chain.length > 1) {
          exitNode = chain.last;
        }
      } catch (_) {
        exitNode = '';
      }
    }
    if (!mounted) {
      return;
    }
    final runner = SpeedTestRunner(findProxy: (_) => proxy);
    _runner = runner;
    setState(() {
      _running = true;
      _phase = SpeedTestPhase.connecting;
      _liveBps = 0;
      _error = null;
      _latencyMs = null;
      _jitterMs = null;
      _downloadBps = null;
      _uploadBps = null;
      _uploadUnsupported = false;
      _serverLabel = '';
      _exitNode = exitNode;
      _routed = routed;
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
        _jitterMs = result.jitterMs;
        _downloadBps = result.downloadBps;
        _uploadBps = result.uploadBps;
        _uploadUnsupported = result.uploadUnsupported;
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
    final gaugeBps = _gaugeBps;
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
          const SizedBox(height: 24),
          _SpeedGauge(
            bps: gaugeBps,
            phaseLabel: _phaseLabel(_phase),
            active: _running,
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _StatCard(
                  label: appLocalizations.delay,
                  value: _latencyText(_latencyMs),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  label: appLocalizations.speedTestJitter,
                  value: _latencyText(_jitterMs),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  label: appLocalizations.download,
                  value: _speedText(_downloadBps),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  label: appLocalizations.upload,
                  value: _uploadUnsupported
                      ? appLocalizations.speedTestNotSupported
                      : _speedText(_uploadBps),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          generateSection(
            items: [
              ListItem(
                title: Text(appLocalizations.server),
                trailing: Text(
                  _serverLabel.isEmpty
                      ? appLocalizations.unknown
                      : _serverLabel,
                ),
              ),
              ListItem(
                title: Text(appLocalizations.speedTestExitNode),
                trailing: Text(
                  _exitNode.isEmpty ? appLocalizations.unknown : _exitNode,
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
          const SizedBox(height: 12),
          Text(
            _serverLabel.isEmpty && !_running
                ? appLocalizations.speedTestTrafficWarning
                : _routed
                ? appLocalizations.speedTestViaProxy
                : appLocalizations.speedTestDirect,
            style: AppTextStyle.footnote.of(context),
            textAlign: TextAlign.center,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
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

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: context.raisedSurfaceLevel.colorOf(colorScheme),
        shape: AppShape.lg,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(color: colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: AppTextStyle.headline.of(context, emphasized: true),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeedGauge extends StatelessWidget {
  const _SpeedGauge({
    required this.bps,
    required this.phaseLabel,
    required this.active,
  });

  final double bps;
  final String phaseLabel;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fraction = bps <= 0
        ? 0.0
        : (bps / speedGaugeScaleMax(bps)).clamp(0.0, 1.0);
    return Center(
      child: SizedBox.square(
        dimension: 248,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size.square(248),
              painter: _GaugePainter(
                fraction: fraction.toDouble(),
                trackColor: context.raisedSurfaceLevel.colorOf(colorScheme),
                valueColor: colorScheme.primary,
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatSpeedValue(bps),
                  style: AppTextStyle.largeTitle.of(context, emphasized: true),
                ),
                Text(
                  formatSpeedUnit(bps),
                  style: AppTextStyle.subheadline
                      .of(context)
                      .copyWith(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                Text(
                  phaseLabel,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  const _GaugePainter({
    required this.fraction,
    required this.trackColor,
    required this.valueColor,
  });

  final double fraction;
  final Color trackColor;
  final Color valueColor;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 14.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - strokeWidth;
    const startAngle = math.pi * 0.75;
    const sweepAngle = math.pi * 1.5;
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      track,
    );
    if (fraction > 0) {
      final value = Paint()
        ..color = valueColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle * fraction,
        false,
        value,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter oldDelegate) {
    return fraction != oldDelegate.fraction ||
        trackColor != oldDelegate.trackColor ||
        valueColor != oldDelegate.valueColor;
  }
}

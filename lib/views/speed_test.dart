import 'dart:math' as math;

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
  double? _latencyMs;
  double? _jitterMs;
  double? _downloadBps;
  double? _uploadBps;
  bool _uploadUnsupported = false;
  String _serverLabel = '';
  String? _error;
  bool _running = false;
  bool _routed = false;
  SpeedTestRunner? _runner;
  final List<double> _samples = [];

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
      _routed = routed;
      _samples.clear();
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
          if ((phase == SpeedTestPhase.download ||
                  phase == SpeedTestPhase.upload) &&
              liveBps > 0) {
            _samples.add(liveBps);
            if (_samples.length > 60) {
              _samples.removeRange(0, _samples.length - 60);
            }
          }
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
                subtitle: Text(_provider.endpointLabel),
                options: SpeedTestProvider.values,
                value: _provider,
                textBuilder: (provider) => provider.label,
                subtitleBuilder: (provider) => provider.endpointLabel,
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
          const SizedBox(height: 16),
          if (_samples.length > 1) ...[
            const SizedBox(height: 16),
            _LiveTrace(samples: _samples, liveBps: _liveBps),
          ],
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth < 600 ? 2 : 4;
              final width =
                  (constraints.maxWidth - (columns - 1) * 8) / columns;
              final stats = [
                (
                  AppGlyphs.clock,
                  appLocalizations.delay,
                  _latencyText(_latencyMs),
                ),
                (
                  AppGlyphs.target,
                  appLocalizations.speedTestJitter,
                  _latencyText(_jitterMs),
                ),
                (
                  AppGlyphs.arrowDown,
                  appLocalizations.download,
                  _speedText(_downloadBps),
                ),
                (
                  AppGlyphs.arrowUp,
                  appLocalizations.upload,
                  _uploadUnsupported
                      ? appLocalizations.speedTestNotSupported
                      : _speedText(_uploadBps),
                ),
              ];
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (glyph, label, value) in stats)
                    SizedBox(
                      width: width,
                      child: _StatCard(
                        glyph: glyph,
                        label: label,
                        value: value,
                      ),
                    ),
                ],
              );
            },
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
                trailing: Text(appLocalizations.speedTestRouteEvidence),
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
  const _StatCard({
    required this.glyph,
    required this.label,
    required this.value,
  });

  final Glyph glyph;
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              spacing: 6,
              children: [
                GlyphIcon(glyph, size: 15, color: colorScheme.primary),
                Flexible(
                  child: Text(
                    label,
                    style: AppTextStyle.caption1
                        .of(context)
                        .copyWith(color: colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: AppTextStyle.headline
                  .of(context, emphasized: true)
                  .toJetBrainsMono,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// The live throughput trace under the gauge, drawn from the samples the
/// runner reports while it measures.
class _LiveTrace extends StatelessWidget {
  const _LiveTrace({required this.samples, required this.liveBps});

  final List<double> samples;
  final double liveBps;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: context.raisedSurfaceLevel.colorOf(colorScheme),
        shape: AppShape.lg,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${formatSpeedValue(liveBps)} ${formatSpeedUnit(liveBps)}',
              style: AppTextStyle.footnote
                  .of(context, emphasized: true)
                  .copyWith(color: colorScheme.primary),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 44,
              width: double.infinity,
              child: CustomPaint(
                painter: _TracePainter(
                  samples: samples,
                  color: colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  const _TracePainter({required this.samples, required this.color});

  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) {
      return;
    }
    final maxValue = samples.reduce(math.max);
    if (maxValue <= 0) {
      return;
    }
    final stepX = size.width / 59;
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i * stepX;
      final y = size.height - (samples[i] / maxValue) * (size.height - 4) - 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill = Path.from(path)
      ..lineTo((samples.length - 1) * stepX, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_TracePainter oldDelegate) =>
      samples != oldDelegate.samples || color != oldDelegate.color;
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

  static const _size = 288.0;
  static const _labelRadius = 100.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final scaleMax = speedGaugeScaleMax(bps <= 0 ? 1 : bps);
    final fraction = bps <= 0
        ? 0.0
        : (bps / scaleMax).clamp(0.0, 1.0).toDouble();
    const center = _size / 2;
    return Center(
      child: SizedBox.square(
        dimension: _size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: fraction),
              duration: context.motionDuration(
                const Duration(milliseconds: 180),
              ),
              builder: (context, value, _) => CustomPaint(
                size: const Size.square(_size),
                painter: _GaugePainter(
                  fraction: value,
                  trackColor: context.raisedSurfaceLevel.colorOf(colorScheme),
                  valueColor: colorScheme.primary,
                  glowColor: const Color(0xff76c8d5),
                ),
              ),
            ),
            for (final mark in [0.0, 0.25, 0.5, 0.75, 1.0])
              Positioned(
                left:
                    center +
                    _labelRadius *
                        math.cos(math.pi * 0.75 + math.pi * 1.5 * mark) -
                    22,
                top:
                    center +
                    _labelRadius *
                        math.sin(math.pi * 0.75 + math.pi * 1.5 * mark) -
                    9,
                child: SizedBox(
                  width: 44,
                  child: Text(
                    formatSpeedValue(scaleMax * mark),
                    textAlign: TextAlign.center,
                    style: AppTextStyle.caption2
                        .of(context)
                        .copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatSpeedValue(bps),
                  style: AppTextStyle.largeTitle
                      .of(context, emphasized: true)
                      .toJetBrainsMono,
                ),
                Text(
                  formatSpeedUnit(bps),
                  style: AppTextStyle.subheadline
                      .of(context)
                      .copyWith(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: colorScheme.primary.withValues(
                      alpha: active ? 0.16 : 0.08,
                    ),
                    shape: AppShape.full,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      phaseLabel,
                      style: AppTextStyle.footnote
                          .of(context)
                          .copyWith(
                            color: active
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
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
    required this.glowColor,
  });

  final double fraction;
  final Color trackColor;
  final Color valueColor;
  final Color glowColor;

  static const _startAngle = math.pi * 0.75;
  static const _sweepAngle = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 2.5;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 26;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final ticks = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i <= 24; i++) {
      final angle = _startAngle + _sweepAngle * i / 24;
      final major = i % 6 == 0;
      final outer = size.width / 2 - 2;
      final inner = outer - (major ? 7 : 3);
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * inner,
        center + Offset(math.cos(angle), math.sin(angle)) * outer,
        ticks,
      );
    }
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, track);
    canvas.drawArc(
      rect.deflate(8),
      _startAngle,
      _sweepAngle,
      false,
      track..color = trackColor.withValues(alpha: 0.5),
    );
    if (fraction > 0) {
      final glow = Paint()
        ..color = valueColor.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 3
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawArc(rect, _startAngle, _sweepAngle * fraction, false, glow);
      final value = Paint()
        ..shader = SweepGradient(
          startAngle: _startAngle,
          endAngle: _startAngle + _sweepAngle,
          colors: [valueColor.withValues(alpha: 0.45), valueColor, glowColor],
          stops: const [0, 0.55, 1],
        ).createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, _startAngle, _sweepAngle * fraction, false, value);
      final endAngle = _startAngle + _sweepAngle * fraction;
      canvas.drawCircle(
        center + Offset(math.cos(endAngle), math.sin(endAngle)) * radius,
        3,
        Paint()..color = glowColor,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter oldDelegate) {
    return fraction != oldDelegate.fraction ||
        trackColor != oldDelegate.trackColor ||
        valueColor != oldDelegate.valueColor ||
        glowColor != oldDelegate.glowColor;
  }
}

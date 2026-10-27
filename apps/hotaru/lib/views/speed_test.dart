import 'dart:math' as math;

import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/ui/ui.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _panelRadius = 12.0;

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

  /// The node the test traffic leaves from: the first visible selector
  /// group's current selection, followed through nested groups. Null
  /// when no profile provides one — shown as unknown, never invented.
  String? _exitNodeName() {
    final groups = ref.watch(groupsProvider);
    var group = groups
        .where(
          (group) => group.type == GroupType.Selector && group.hidden != true,
        )
        .firstOrNull;
    String? name;
    var guard = 0;
    while (group != null && guard++ < 8) {
      name = ref.watch(selectedProxyNameProvider(group.name));
      if (name == null) {
        break;
      }
      group = groups.getGroup(name);
    }
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final exitNode = _exitNodeName();
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );

    Widget panel({required Widget child}) => DecoratedBox(
      decoration: ShapeDecoration(
        color: colorScheme.surfaceContainer,
        shape: AppShape.all(_panelRadius),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );

    final gaugePanel = panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _NeedleGauge(
            bps: _gaugeBps,
            phaseLabel: _phaseLabel(_phase),
            active: _running,
          ),
          const SizedBox(height: 8),
          _PhaseDots(phase: _phase, uploadUnsupported: _uploadUnsupported),
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _running ? _stop : _start,
              child: Text(
                _running ? appLocalizations.stop : appLocalizations.start,
                style: AppTextStyle.title3.of(context, emphasized: true),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _routed
                ? appLocalizations.speedTestViaProxy
                : appLocalizations.speedTestDirect,
            style: AppTextStyle.footnote
                .of(context)
                .copyWith(color: colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              '${appLocalizations.error}: $_error',
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),
          _StatTiles(
            stats: [
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
            ],
          ),
        ],
      ),
    );

    final infoPanel = panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          const SizedBox(height: 4),
          const Divider(height: 1),
          const SizedBox(height: 4),
          _InfoRow(
            label: appLocalizations.speedTestExitNode,
            value: exitNode ?? appLocalizations.unknown,
          ),
          _InfoRow(
            label: appLocalizations.route,
            value: switch (mode) {
              Mode.rule => appLocalizations.rule,
              Mode.global => appLocalizations.global,
              Mode.direct => appLocalizations.direct,
            },
          ),
          _InfoRow(
            label: appLocalizations.server,
            value: _serverLabel.isEmpty
                ? _provider.endpointLabel
                : _serverLabel,
            flag: _provider == SpeedTestProvider.vultr ? 'JP' : null,
          ),
        ],
      ),
    );

    final tracePanel = panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                appLocalizations.speedTestLiveRate,
                style: AppTextStyle.subheadline.of(context, emphasized: true),
              ),
              const Spacer(),
              Text(
                _samples.isEmpty
                    ? appLocalizations.speedTestNotRun
                    : '${formatSpeedValue(_liveBps)} ${formatSpeedUnit(_liveBps)}',
                style: AppTextStyle.footnote
                    .of(context, emphasized: true)
                    .copyWith(color: colorScheme.primary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 64,
            width: double.infinity,
            child: _samples.length > 1
                ? CustomPaint(
                    painter: _TracePainter(
                      samples: _samples,
                      color: colorScheme.primary,
                    ),
                  )
                : CustomPaint(
                    painter: _TraceBaselinePainter(
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.25,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );

    final attribution = Text(
      '${_provider.label} · ${appLocalizations.speedTestTrafficWarning}',
      style: AppTextStyle.caption1
          .of(context)
          .copyWith(color: colorScheme.onSurfaceVariant),
    );

    return BaseScaffold(
      title: appLocalizations.speedTest,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 920;
          if (!wide) {
            return ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                context.appBarInset + 12,
                16,
                24 + context.bottomInset,
              ),
              children: [
                gaugePanel,
                const SizedBox(height: 12),
                infoPanel,
                const SizedBox(height: 12),
                tracePanel,
                const SizedBox(height: 12),
                attribution,
              ],
            );
          }
          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              context.appBarInset + 12,
              16,
              16 + context.bottomInset,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 6, child: gaugePanel),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      infoPanel,
                      const SizedBox(height: 12),
                      tracePanel,
                      const SizedBox(height: 12),
                      attribution,
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One label/value line of the run's info card.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.flag});

  final String label;
  final String value;
  final String? flag;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        spacing: 10,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: AppTextStyle.subheadline
                  .of(context)
                  .copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
          if (flag != null) FlagIcon(countryCode: flag, width: 22),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: AppTextStyle.subheadline.of(context, emphasized: true),
            ),
          ),
        ],
      ),
    );
  }
}

/// The four result tiles under the start button: download, upload,
/// latency, jitter.
class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.stats});

  final List<(Glyph, String, String)> stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 480 ? 2 : 4;
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (glyph, label, value) in stats)
              SizedBox(
                width: width,
                child: _StatCard(glyph: glyph, label: label, value: value),
              ),
          ],
        );
      },
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
        color: colorScheme.surfaceContainerHigh,
        shape: AppShape.all(_panelRadius),
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

/// The three run phases as a dotted progress row: latency, download,
/// upload. A phase fills as it completes; the running one pulses.
class _PhaseDots extends StatelessWidget {
  const _PhaseDots({required this.phase, required this.uploadUnsupported});

  final SpeedTestPhase? phase;
  final bool uploadUnsupported;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final labels = [
      appLocalizations.delay,
      appLocalizations.download,
      appLocalizations.upload,
    ];
    final current = switch (phase) {
      null => -1,
      SpeedTestPhase.connecting || SpeedTestPhase.latency => 0,
      SpeedTestPhase.download => 1,
      SpeedTestPhase.upload => 2,
      SpeedTestPhase.done => 3,
    };
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                color: i <= current
                    ? context.colorScheme.primary
                    : context.colorScheme.surfaceContainerHighest,
              ),
            ),
          _PhaseDot(
            label: labels[i],
            done: i < current || phase == SpeedTestPhase.done,
            active: i == current,
            skipped:
                phase == SpeedTestPhase.done && i == 2 && uploadUnsupported,
          ),
        ],
      ],
    );
  }
}

class _PhaseDot extends StatelessWidget {
  const _PhaseDot({
    required this.label,
    required this.done,
    required this.active,
    required this.skipped,
  });

  final String label;
  final bool done;
  final bool active;
  final bool skipped;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final color = skipped
        ? colorScheme.onSurfaceVariant
        : done || active
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: ShapeDecoration(
            color: done && !skipped ? colorScheme.primary : Colors.transparent,
            shape: AppShape.full.copyWith(
              side: BorderSide(color: color, width: 2),
            ),
          ),
          child: active
              ? Center(
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: ShapeDecoration(
                      color: colorScheme.primary,
                      shape: AppShape.full,
                    ),
                  ),
                )
              : null,
        ),
        const SizedBox(height: 6),
        Text(
          skipped
              ? '$label · ${context.appLocalizations.speedTestNotSupported}'
              : label,
          style: AppTextStyle.caption1
              .of(context, emphasized: done || active)
              .copyWith(color: color),
        ),
      ],
    );
  }
}

/// The flat baseline the live trace shows before a run has samples.
class _TraceBaselinePainter extends CustomPainter {
  const _TraceBaselinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height - 2;
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_TraceBaselinePainter oldDelegate) =>
      color != oldDelegate.color;
}

/// The live throughput trace, drawn from the samples the runner
/// reports while it measures.
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

/// A physical needle over a segmented scale — 0 / 5 / 10 / 50 / 100 /
/// 250 / 500 / 750 / 1G+ Mbps, one equal arc per segment — with the
/// measured arc lit behind it and the live value under the hub.
class _NeedleGauge extends StatelessWidget {
  const _NeedleGauge({
    required this.bps,
    required this.phaseLabel,
    required this.active,
  });

  final double bps;
  final String phaseLabel;
  final bool active;

  static const _size = 300.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fraction = speedNeedleFraction(bps);
    return Center(
      child: SizedBox.square(
        dimension: _size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: fraction),
              duration: context.motionDuration(
                const Duration(milliseconds: 220),
              ),
              builder: (context, value, _) => CustomPaint(
                size: const Size.square(_size),
                painter: _NeedlePainter(
                  fraction: value,
                  trackColor: colorScheme.surfaceContainerHighest,
                  valueColor: colorScheme.primary,
                  needleColor: colorScheme.onSurface,
                  labelStyle: AppTextStyle.caption2
                      .of(context)
                      .copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
            ),
            Positioned(
              top: _size / 2 + 34,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    spacing: 5,
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
                    ],
                  ),
                  const SizedBox(height: 6),
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
            ),
          ],
        ),
      ),
    );
  }
}

class _NeedlePainter extends CustomPainter {
  const _NeedlePainter({
    required this.fraction,
    required this.trackColor,
    required this.valueColor,
    required this.needleColor,
    required this.labelStyle,
  });

  final double fraction;
  final Color trackColor;
  final Color valueColor;
  final Color needleColor;
  final TextStyle labelStyle;

  static const _startAngle = math.pi * 0.75;
  static const _sweepAngle = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 30;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Segment ticks: five subdivisions per segment, the breakpoints
    // longer, drawn inside the rim.
    final tickPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final segments = speedDialMarksMbps.length - 1;
    for (var i = 0; i <= segments * 5; i++) {
      final breakpoint = i % 5 == 0;
      final angle = _startAngle + _sweepAngle * i / (segments * 5);
      final outer = size.width / 2 - 4;
      final inner = outer - (breakpoint ? 10 : 5);
      tickPaint.strokeWidth = breakpoint ? 2 : 1;
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * inner,
        center + Offset(math.cos(angle), math.sin(angle)) * outer,
        tickPaint,
      );
    }

    // Track and measured arc.
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, track);
    if (fraction > 0) {
      final value = Paint()
        ..shader = SweepGradient(
          startAngle: _startAngle,
          endAngle: _startAngle + _sweepAngle,
          colors: [valueColor.withValues(alpha: 0.5), valueColor],
        ).createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, _startAngle, _sweepAngle * fraction, false, value);
    }

    // Breakpoint labels around the dial.
    for (var i = 0; i < speedDialMarksMbps.length; i++) {
      final angle = _startAngle + _sweepAngle * i / segments;
      final mark = speedDialMarksMbps[i];
      final text = mark >= 1000 ? '1G+' : '${mark.toInt()}';
      final painter = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final at =
          center + Offset(math.cos(angle), math.sin(angle)) * (radius - 26);
      painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
    }

    // The needle: a tapered hand from the hub to just inside the arc.
    final angle = _startAngle + _sweepAngle * fraction;
    final direction = Offset(math.cos(angle), math.sin(angle));
    final perpendicular = Offset(-direction.dy, direction.dx);
    final tip = center + direction * (radius - 16);
    final base = center - direction * 16;
    final needle = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo((base + perpendicular * 5.5).dx, (base + perpendicular * 5.5).dy)
      ..lineTo((base - perpendicular * 5.5).dx, (base - perpendicular * 5.5).dy)
      ..close();
    canvas.drawPath(
      needle,
      Paint()
        ..color = needleColor
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(center, 10, Paint()..color = valueColor);
    canvas.drawCircle(center, 4.5, Paint()..color = needleColor);
  }

  @override
  bool shouldRepaint(_NeedlePainter oldDelegate) =>
      fraction != oldDelegate.fraction ||
      trackColor != oldDelegate.trackColor ||
      valueColor != oldDelegate.valueColor ||
      needleColor != oldDelegate.needleColor ||
      labelStyle != oldDelegate.labelStyle;
}

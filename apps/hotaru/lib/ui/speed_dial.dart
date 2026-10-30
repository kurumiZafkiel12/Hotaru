import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';

class SpeedDialPainter extends CustomPainter {
  const SpeedDialPainter({
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
    final needleAngle = _startAngle + _sweepAngle * fraction.clamp(0, 1);
    final direction = Offset(math.cos(needleAngle), math.sin(needleAngle));
    canvas.drawLine(
      center - direction * 10,
      center + direction * (radius - 12),
      Paint()
        ..color = valueColor
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(center, 5, Paint()..color = valueColor);
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
  bool shouldRepaint(SpeedDialPainter oldDelegate) {
    return fraction != oldDelegate.fraction ||
        trackColor != oldDelegate.trackColor ||
        valueColor != oldDelegate.valueColor ||
        glowColor != oldDelegate.glowColor;
  }
}

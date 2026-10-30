import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'typography.dart';
import 'shape.dart';

class AppArrival extends StatefulWidget {
  const AppArrival({
    super.key,
    required this.child,
    this.brandMark,
    this.brandLabel,
  });

  final Widget child;
  final Widget? brandMark;
  final String? brandLabel;

  @override
  State<AppArrival> createState() => _AppArrivalState();
}

class _AppArrivalState extends State<AppArrival>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.brandMark == null ? 250 : 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else if (!_controller.isAnimating && _controller.value == 0) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final intro = widget.brandMark != null;
      final value = _controller.value;
      final page = intro ? ((value - 0.72) / 0.28).clamp(0.0, 1.0) : value;
      final progress = Curves.easeOutCubic.transform(page);
      final colorScheme = Theme.of(context).colorScheme;
      return ColoredBox(
        color: colorScheme.surface,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            if (progress < 1)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 0.24 + progress * 0.05,
                      colors: [
                        colorScheme.primary.withValues(
                          alpha: 0.035 * (1 - progress),
                        ),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            Opacity(
              opacity: progress,
              child: IgnorePointer(
                ignoring: progress < 1,
                child: Transform.translate(
                  offset: Offset(0, 2 * (1 - progress)),
                  child: child,
                ),
              ),
            ),
            if (intro && value < 1)
              Positioned.fill(
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: Opacity(
                      opacity: 1 - progress,
                      child: _BrandArrival(
                        progress: value,
                        label: widget.brandLabel,
                        child: widget.brandMark!,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _BrandArrival extends StatelessWidget {
  const _BrandArrival({
    required this.progress,
    required this.label,
    required this.child,
  });
  final double progress;
  final String? label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reveal = Curves.easeOutCubic.transform(
      (progress / 0.4).clamp(0.0, 1.0),
    );
    final ripple = ((progress - 0.2) / 0.55).clamp(0.0, 1.0);
    final text = ((progress - 0.42) / 0.28).clamp(0.0, 1.0);
    return Center(
      child: SizedBox(
        width: 240,
        height: 280,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ArrivalParticles(
                  progress,
                  Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            Positioned(
              top: 46,
              child: Transform.scale(
                scale: 0.85 + 0.15 * reveal,
                child: Opacity(
                  opacity: reveal,
                  child: SizedBox.square(dimension: 112, child: child),
                ),
              ),
            ),
            if (ripple > 0 && ripple < 1)
              Positioned(
                top: 102 - (56 + ripple * 40),
                child: SizedBox.square(
                  dimension: (56 + ripple * 40) * 2,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: AppShape.circle.copyWith(
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: 0.12 * (1 - ripple)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (label != null)
              Positioned(
                top: 184,
                child: Opacity(
                  opacity: text,
                  child: Transform.translate(
                    offset: Offset(0, 2 * (1 - text)),
                    child: Text(
                      label!,
                      style: AppTextStyle.title3.of(context, emphasized: true),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ArrivalParticles extends CustomPainter {
  const _ArrivalParticles(this.progress, this.color);
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final converge = Curves.easeInOutCubic.transform(
      (progress / 0.48).clamp(0.0, 1.0),
    );
    final alpha = (math.sin(
      progress.clamp(0.0, 0.6) / 0.6 * math.pi,
    )).clamp(0.0, 1.0);
    final center = Offset(size.width / 2, 102);
    for (var index = 0; index < 18; index++) {
      final angle = index * 2.399963;
      final radius = 70.0 + (index % 4) * 14;
      final start = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      final t = (index % 6) / 5;
      final end = center + Offset(-27 + 54 * t, 27 - 54 * t);
      final point = Offset.lerp(start, end, converge)!;
      canvas.drawCircle(
        point,
        1.2 + (index % 3) * 0.5,
        Paint()..color = color.withValues(alpha: alpha * 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(_ArrivalParticles oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

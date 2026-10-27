import 'package:material_ui/material_ui.dart';

class AppArrival extends StatefulWidget {
  const AppArrival({super.key, required this.child});

  final Widget child;

  @override
  State<AppArrival> createState() => _AppArrivalState();
}

class _AppArrivalState extends State<AppArrival>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
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
      final progress = Curves.easeOutCubic.transform(_controller.value);
      return ColoredBox(
        color: const Color(0xff111317),
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
                        const Color(
                          0xff34d399,
                        ).withValues(alpha: 0.035 * (1 - progress)),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            Opacity(
              opacity: progress,
              child: Transform.translate(
                offset: Offset(0, 2 * (1 - progress)),
                child: child,
              ),
            ),
          ],
        ),
      );
    },
  );
}

import 'dart:math' as math;

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/features/features.dart';
import 'package:hotaru/features/ip_quality/labels.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/ip_quality.dart';
import 'package:hotaru/providers/outbound_ip.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/providers/routed_probe.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dashboard/probe_start_hold.dart';
import 'package:hotaru/views/dashboard/style.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_ui/material_ui.dart';

import 'card.dart';

const _builtinOutbounds = {'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS'};

bool isBuiltinOutbound(String name) => _builtinOutbounds.contains(name);

const _ipMask = '*****';

/// The address the proxied traffic leaves by, next to the start button.
class CurrentOutboundCard extends ConsumerStatefulWidget {
  const CurrentOutboundCard({super.key});

  @override
  ConsumerState<CurrentOutboundCard> createState() =>
      _CurrentOutboundCardState();
}

class _CurrentOutboundCardState extends ConsumerState<CurrentOutboundCard>
    with ProbeStartHold<CurrentOutboundCard> {
  late final OutboundIpProbe _probe;

  @override
  void initState() {
    super.initState();
    _probe = ref.read(outboundIpProbeProvider.notifier)..watch(routedOutbound);
  }

  @override
  void dispose() {
    _probe.unwatch(routedOutbound);
    super.dispose();
  }

  void _refresh(String? ip) {
    _probe.refresh(const [routedOutbound]);
    if (ip != null && ref.read(ipQualityProvider(ip)).hasError) {
      ref.invalidate(ipQualityProvider(ip));
    }
  }

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final hasProfile = ref.watch(
      profilesProvider.select((state) => state.isNotEmpty),
    );
    final isStart = ref.watch(isStartProvider);
    final suspended = isStart && ref.watch(suspendProvider);
    final entry = ref.watch(
      outboundIpProbeProvider.select((state) => state.entryOf(routedOutbound)),
    );
    final ipInfo = entry.value;
    final phase = shownPhase(entry);
    final failed = phase == ProbePhase.failed && ipInfo == null;
    final qualityState = ipInfo == null
        ? null
        : ref.watch(ipQualityProvider(ipInfo.ip));
    final quality = qualityState?.value;
    final qualityLoading =
        qualityState != null && quality == null && qualityState.isLoading;
    final loading = ipInfo == null ? !failed : qualityLoading;
    final metrics = _OutboundMetrics.of(density);
    final appLocalizations = context.appLocalizations;
    final (chipLabel, chipTone) = suspended
        ? (appLocalizations.suspended, DashboardChipTone.warn)
        : isStart
        ? (appLocalizations.running, DashboardChipTone.ok)
        : (appLocalizations.notRunning, DashboardChipTone.idle);
    return DashboardCard(
      padding: EdgeInsets.zero,
      highlighted: true,
      semanticLabel: appLocalizations.status,
      child: Padding(
        padding: metrics.padding,
        child: Row(
          spacing: metrics.gap,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DashboardCardHeader(
                    glyph: AppGlyphs.status,
                    title: appLocalizations.status,
                    leading: [
                      DashboardChip(
                        label: chipLabel,
                        tone: chipTone,
                        dot: isStart,
                      ),
                    ],
                  ),
                  SizedBox(height: metrics.ipTop),
                  _ExitRow(
                    info: ipInfo,
                    failed: failed,
                    loading: loading,
                    checking: phase == ProbePhase.probing || qualityLoading,
                    onRefresh: () => _refresh(ipInfo?.ip),
                    quality: quality,
                    active: isStart,
                    metrics: metrics,
                    large: true,
                  ),
                  if (density.isDesktop)
                    const Spacer()
                  else
                    const SizedBox(height: 16),
                  if (!density.isDesktop || !failed)
                    _Cells(
                      quality: quality,
                      loading: loading,
                      active: isStart && !suspended,
                      gap: metrics.cellGap,
                      inline: density.isDesktop,
                    ),
                ],
              ),
            ),
            SizedBox(
              width: metrics.buttonSlot,
              child: Center(
                child: _StartToggle(
                  size: metrics.buttonSize,
                  enabled: hasProfile,
                  running: isStart,
                  suspended: suspended,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutboundMetrics {
  const _OutboundMetrics({
    required this.padding,
    required this.gap,
    required this.ipTop,
    required this.cellGap,
    required this.badgeSize,
    required this.ip,
    required this.buttonSize,
    required this.buttonSlot,
  });

  factory _OutboundMetrics.of(DashboardDensity density) => switch (density) {
    DashboardDensity.standard => _OutboundMetrics(
      padding: dashboardCardPadding(density),
      gap: 12,
      ipTop: 6,
      cellGap: 24,
      badgeSize: 40,
      ip: AppTextStyle.title1,
      buttonSize: 72,
      buttonSlot: 88,
    ),
    DashboardDensity.compact => _OutboundMetrics(
      padding: dashboardCardPadding(density),
      gap: 12,
      ipTop: 4,
      cellGap: 20,
      badgeSize: 36,
      ip: AppTextStyle.title2,
      buttonSize: 64,
      buttonSlot: 76,
    ),
    DashboardDensity.mobile => const _OutboundMetrics(
      padding: EdgeInsetsDirectional.fromSTEB(12, 12, 12, 12),
      gap: 10,
      ipTop: 6,
      cellGap: 24,
      badgeSize: 48,
      ip: AppTextStyle.title2,
      buttonSize: 56,
      buttonSlot: 64,
    ),
  };

  final EdgeInsetsGeometry padding;
  final double gap;
  final double ipTop;
  final double cellGap;
  final double badgeSize;
  final AppTextStyle ip;
  final double buttonSize;
  final double buttonSlot;
}

class _ExitRow extends StatelessWidget {
  const _ExitRow({
    required this.info,
    required this.failed,
    required this.loading,
    required this.checking,
    required this.onRefresh,
    required this.quality,
    required this.active,
    required this.metrics,
    required this.large,
  });

  final IpInfo? info;
  final bool failed;
  final bool loading;
  final bool checking;
  final VoidCallback onRefresh;
  final IpQuality? quality;
  final bool active;
  final _OutboundMetrics metrics;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final style = DashboardText.figure(
      context,
      metrics.ip,
      color: active ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
    ).copyWith(letterSpacing: 0);
    final info = this.info;
    final appLocalizations = context.appLocalizations;
    final Widget ip = info != null
        ? Tooltip(
            message: appLocalizations.details(appLocalizations.outboundIp),
            child: FocusRing(
              shape: AppShape.xs,
              standsOff: true,
              child: InkWell(
                onTap: () => showIpQualitySheet(context, ip: info.ip),
                customBorder: AppShape.xs,
                hoverColor: Colors.transparent,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                child: _IpText(ip: info.ip, style: style),
              ),
            ),
          )
        : failed
        ? Text(
            appLocalizations.serviceFailed,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(color: colorScheme.error),
          )
        : SkeletonText(width: 140, style: style);
    return Row(
      spacing: 12,
      children: [
        _CountryBadge(
          countryCode: info?.countryCode,
          size: metrics.badgeSize,
          active: active,
          checking: checking,
          onRefresh: onRefresh,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height:
                    metrics.ip.leading * DashboardDensityScope.scaleOf(context),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ip,
                ),
              ),
              if (failed || large) const SizedBox(height: 4),
              if (failed)
                SizedBox(
                  height: _chipHeight(large),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      appLocalizations.tapIconToRetry,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DashboardText.label(context),
                    ),
                  ),
                )
              else if (large)
                _IpChips(quality: quality, loading: loading, large: large),
            ],
          ),
        ),
      ],
    );
  }
}

class _IpText extends ConsumerWidget {
  const _IpText({required this.ip, required this.style});

  final String ip;
  final TextStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hideIp = ref.watch(
      appSettingProvider.select((state) => state.hideIp),
    );
    return DashboardFitText(hideIp ? _ipMask : ip, style: style);
  }
}

double _chipHeight(bool large) => large ? 28 : 24;

const _chipSkeletonWidths = [48.0, 72.0];

class _IpChips extends StatelessWidget {
  const _IpChips({
    required this.quality,
    required this.loading,
    required this.large,
  });

  final IpQuality? quality;
  final bool loading;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final quality = this.quality;
    final height = _chipHeight(large);
    // Chips that do not fit wrap onto a clipped second line; the details
    // sheet still lists them all.
    return SizedBox(
      height: height,
      child: ClipRect(
        child: Wrap(
          spacing: 6,
          runSpacing: height,
          children: switch (quality) {
            final quality? => [
              DashboardChip(label: quality.type.label(context), large: large),
              DashboardChip(
                label:
                    '${context.appLocalizations.ipQualityShort} ${quality.level.label(context)}',
                tone: switch (quality.level) {
                  IpQualityLevel.good => DashboardChipTone.ok,
                  IpQualityLevel.normal => DashboardChipTone.idle,
                  IpQualityLevel.risky => DashboardChipTone.warn,
                },
                large: large,
              ),
            ],
            null when loading => [
              for (final width in _chipSkeletonWidths)
                SkeletonPill(width: width, height: height),
            ],
            null => [
              DashboardChip(
                label: context.appLocalizations.ipTypeUnknown,
                large: large,
              ),
            ],
          },
        ),
      ),
    );
  }
}

const _spinPeriod = Duration(milliseconds: 1500);

/// The exit's country on a clover that checks the exit again when tapped and
/// turns while it is being checked.
class _CountryBadge extends StatefulWidget {
  const _CountryBadge({
    required this.countryCode,
    required this.size,
    required this.active,
    required this.checking,
    required this.onRefresh,
  });

  final String? countryCode;
  final double size;
  final bool active;
  final bool checking;
  final VoidCallback onRefresh;

  @override
  State<_CountryBadge> createState() => _CountryBadgeState();
}

class _CountryBadgeState extends State<_CountryBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: _spinPeriod,
  );
  var _hovered = false;
  var _focused = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _spin();
  }

  @override
  void didUpdateWidget(_CountryBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.checking != widget.checking) {
      _spin();
    }
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  void _spin() {
    if (context.disableAnimations) {
      _turns.value = 0;
    } else if (widget.checking) {
      _turns.repeat();
    } else {
      // A clover looks the same every quarter turn, so it stops on the next.
      final rest = (_turns.value * 4).ceil() / 4;
      _turns.animateTo(rest, duration: _spinPeriod * (rest - _turns.value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final foreground = widget.active
        ? colorScheme.onSurface
        : colorScheme.onSurfaceVariant;
    final enabled = !widget.checking;
    final size = widget.size;
    final code = widget.countryCode;
    final tooltip = context.appLocalizations.retry;
    final color = Color.alphaBlend(
      foreground.withValues(alpha: enabled && _hovered ? 0.08 : 0),
      DashboardColors.of(context).tone2,
    );
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: InkResponse(
          onTap: enabled ? widget.onRefresh : null,
          onHover: (value) => setState(() => _hovered = value),
          onFocusChange: (value) => setState(() => _focused = value),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          child: ElasticPress(
            enabled: enabled,
            child: AnimatedBuilder(
              animation: _turns,
              builder: (_, child) => ShapeBadge(
                shape: MaterialShapes.clover4Leaf,
                color: color,
                size: size,
                rotation: _turns.value * 2 * math.pi,
                ring: _focused ? focusRingSide(colorScheme) : null,
                child: child,
              ),
              child: code == null || code.isEmpty
                  ? GlyphIcon(
                      AppGlyphs.proxies,
                      size: size * 0.42,
                      color: foreground,
                    )
                  : Text(
                      code.countryFlagEmoji,
                      maxLines: 1,
                      style: AppTextStyle.custom(
                        context,
                        size: size * 0.78,
                        leading: size * 0.9,
                      ).copyWith(fontFamily: FontFamily.twEmoji.value),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Cells extends StatelessWidget {
  const _Cells({
    required this.quality,
    required this.loading,
    required this.active,
    required this.gap,
    this.inline = false,
  });

  final IpQuality? quality;
  final bool loading;
  final bool active;
  final double gap;

  /// Label and value share one line, the compact desktop arrangement.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final organization = switch (quality) {
      IpQuality(organization: final name?) when name.isNotEmpty => name,
      IpQuality(asn: final asn?) => 'AS$asn',
      _ => null,
    };
    return Row(
      spacing: gap,
      children: [
        _Cell(
          label: appLocalizations.runTime,
          inline: inline,
          value: active ? const _RunTimeValue() : const _Placeholder(),
        ),
        Flexible(
          child: _Cell(
            label: appLocalizations.ipOrganization,
            inline: inline,
            value: organization != null
                ? _CellText(organization)
                : loading
                ? SkeletonText(width: 96, style: _cellStyle(context))
                : const _Placeholder(),
          ),
        ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.value, this.inline = false});

  final String label;
  final Widget value;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: DashboardText.label(context),
    );
    if (inline) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          labelText,
          Flexible(child: value),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [labelText, const SizedBox(height: 2), value],
    );
  }
}

TextStyle _cellStyle(BuildContext context) =>
    AppTextStyle.subheadline.of(context, emphasized: true).toTabular;

class _CellText extends StatelessWidget {
  const _CellText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _cellStyle(context),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Text('—', maxLines: 1, style: _cellStyle(context));
  }
}

class _RunTimeValue extends ConsumerWidget {
  const _RunTimeValue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CellText(getTimeText(ref.watch(runTimeProvider)));
  }
}

class _StartToggle extends ConsumerStatefulWidget {
  const _StartToggle({
    required this.size,
    required this.enabled,
    required this.running,
    required this.suspended,
  });

  final double size;
  final bool enabled;
  final bool running;
  final bool suspended;

  @override
  ConsumerState<_StartToggle> createState() => _StartToggleState();
}

class _StartToggleState extends ConsumerState<_StartToggle>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(_StartToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  void _syncMotion() {
    if (widget.running &&
        !widget.suspended &&
        !MediaQuery.disableAnimationsOf(context)) {
      if (!_wave.isAnimating) _wave.repeat();
    } else {
      _wave.stop();
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final label = widget.suspended
        ? l10n.suspended
        : widget.running
        ? l10n.stop
        : l10n.start;
    final foreground = SizedBox.square(
      dimension: widget.size,
      child: Center(
        child: GlyphIcon(
          widget.suspended
              ? AppGlyphs.wifiOff
              : AppGlyphs.playPause(widget.running ? 1 : 0),
          size: widget.size * 0.32,
          color: widget.enabled
              ? Colors.white
              : context.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        label: label,
        child: FocusRing(
          shape: AppShape.full,
          child: InkResponse(
            onHighlightChanged: (pressed) => setState(() => _pressed = pressed),
            onTap: widget.enabled
                ? () => ref.read(commonActionProvider.notifier).toggleRunning()
                : null,
            customBorder: AppShape.full,
            child: ElasticPress(
              enabled: widget.enabled,
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _wave,
                  builder: (context, child) => CustomPaint(
                    painter: _WavePainter(
                      phase: _wave.value * math.pi * 2,
                      active: widget.running && !widget.suspended,
                      enabled: widget.enabled,
                    ),
                    child: child,
                  ),
                  child: LiquidGlassScope.of(context)
                      ? LiquidGlass(
                          style: LiquidGlassStyle.tinted(
                            context.colorScheme,
                            const Color(0xff235269),
                          ),
                          clipper: const ShapeBorderClipper(
                            shape: AppShape.full,
                          ),
                          pressed: _pressed,
                          child: foreground,
                        )
                      : foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.phase,
    required this.active,
    required this.enabled,
  });

  final double phase;
  final bool active;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 3;
    final outline = Path();
    for (var i = 0; i <= 120; i++) {
      final angle = math.pi * 2 * i / 120;
      final r = radius + (active ? math.sin(angle * 3 + phase) * 1.5 : 0);
      final point = center + Offset(math.cos(angle), math.sin(angle)) * r;
      if (i == 0) {
        outline.moveTo(point.dx, point.dy);
      } else {
        outline.lineTo(point.dx, point.dy);
      }
    }
    outline.close();
    canvas.drawPath(outline, Paint()..color = const Color(0xff202e3b));
    canvas.save();
    canvas.clipPath(outline);
    final wave = Path()..moveTo(0, size.height);
    for (var x = 0.0; x <= size.width; x += 2) {
      final y =
          size.height * (active ? 0.4 : 0.72) +
          math.sin(x / size.width * math.pi * 2 + phase) * size.height * 0.055;
      wave.lineTo(x, y);
    }
    wave
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(
      wave,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: enabled
              ? const [Color(0xff438d9d), Color(0xff235269)]
              : const [Color(0xff303943), Color(0xff27313a)],
        ).createShader(Offset.zero & size),
    );
    canvas.restore();
    canvas.drawPath(
      outline,
      Paint()
        ..color = const Color(
          0xff75bac5,
        ).withValues(alpha: active ? 0.65 : 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      phase != oldDelegate.phase ||
      active != oldDelegate.active ||
      enabled != oldDelegate.enabled;
}

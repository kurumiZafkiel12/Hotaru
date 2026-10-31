import 'dart:math' as math;

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/country_names.dart';
import 'package:hotaru/common/network_quality.dart';
import 'package:hotaru/providers/network_quality.dart';
import 'package:hotaru/views/network_quality.dart';
import 'package:hotaru/common/service_probe.dart';
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
  late final NetworkQuality _networkQuality;

  @override
  void initState() {
    super.initState();
    _probe = ref.read(outboundIpProbeProvider.notifier)..watch(routedOutbound);
    _networkQuality = ref.read(networkQualityProvider.notifier)..watch();
  }

  @override
  void dispose() {
    _probe.unwatch(routedOutbound);
    _networkQuality.unwatch();
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
    final country = _CountryColumn(
      countryCode: ipInfo?.countryCode,
      metrics: metrics,
      active: isStart,
      checking: phase == ProbePhase.probing,
      onRefresh: () => _refresh(ipInfo?.ip),
    );
    final status = _StatusLine(label: chipLabel, tone: chipTone);
    final address = _ExitRow(
      info: ipInfo,
      failed: failed,
      metrics: metrics,
      active: isStart,
    );
    final dimensions = _IpDimensions(quality: quality, loading: qualityLoading);
    final metadata = _Cells(
      quality: quality,
      loading: loading,
      active: isStart && !suspended,
      gap: metrics.cellGap,
      inline: density.isDesktop,
    );
    final toggle = SizedBox(
      width: metrics.buttonSlot,
      child: Center(
        heightFactor: 1,
        child: _StartToggle(
          size: metrics.buttonSize,
          enabled: hasProfile,
          running: isStart,
          suspended: suspended,
        ),
      ),
    );
    return DashboardCard(
      padding: metrics.padding,
      highlighted: true,
      semanticLabel: appLocalizations.status,
      child: density.isDesktop
          ? Row(
              spacing: metrics.gap,
              children: [
                country,
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: DashboardDensityScope.scaleOf(context) > 1
                        ? [
                            Row(
                              spacing: 8,
                              children: [
                                Expanded(flex: 3, child: address),
                                Flexible(child: status),
                              ],
                            ),
                            dimensions,
                            metadata,
                          ]
                        : [status, address, dimensions, metadata],
                  ),
                ),
                toggle,
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                Row(
                  spacing: metrics.gap,
                  children: [
                    country,
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [status, address],
                      ),
                    ),
                    toggle,
                  ],
                ),
                dimensions,
                metadata,
              ],
            ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.label, required this.tone});

  final String label;
  final DashboardChipTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = DashboardColors.of(context);
    final color = switch (tone) {
      DashboardChipTone.ok => colors.ok,
      DashboardChipTone.warn => colors.warn,
      DashboardChipTone.idle => context.colorScheme.onSurfaceVariant,
    };
    return Semantics(
      liveRegion: true,
      child: Row(
        spacing: 6,
        children: [
          DecoratedBox(
            decoration: ShapeDecoration(color: color, shape: AppShape.circle),
            child: const SizedBox.square(dimension: 6),
          ),
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              style: DashboardText.label(context, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _OutboundMetrics {
  const _OutboundMetrics({
    required this.padding,
    required this.gap,
    required this.cellGap,
    required this.badgeSize,
    required this.ip,
    required this.buttonSize,
    required this.buttonSlot,
  });

  factory _OutboundMetrics.of(DashboardDensity density) => switch (density) {
    DashboardDensity.standard => _OutboundMetrics(
      padding: dashboardCardPadding(density),
      gap: 10,
      cellGap: 12,
      badgeSize: 40,
      ip: AppTextStyle.title1,
      buttonSize: DashboardSizing.desktopStartButton,
      buttonSlot: 60,
    ),
    DashboardDensity.compact => _OutboundMetrics(
      padding: dashboardCardPadding(density),
      gap: 8,
      cellGap: 8,
      badgeSize: 36,
      ip: AppTextStyle.title2,
      buttonSize: DashboardSizing.desktopStartButton,
      buttonSlot: 60,
    ),
    DashboardDensity.mobile => const _OutboundMetrics(
      padding: EdgeInsetsDirectional.fromSTEB(12, 12, 12, 12),
      gap: 8,
      cellGap: 8,
      badgeSize: 36,
      ip: AppTextStyle.title2,
      buttonSize: 56,
      buttonSlot: 56,
    ),
  };

  final EdgeInsetsGeometry padding;
  final double gap;
  final double cellGap;
  final double badgeSize;
  final AppTextStyle ip;
  final double buttonSize;
  final double buttonSlot;
}

class _CountryColumn extends StatelessWidget {
  const _CountryColumn({
    required this.countryCode,
    required this.metrics,
    required this.active,
    required this.checking,
    required this.onRefresh,
  });

  final String? countryCode;
  final _OutboundMetrics metrics;
  final bool active;
  final bool checking;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final code = countryCode?.trim().toUpperCase();
    final name = countryName(
      code,
      Localizations.localeOf(context).languageCode,
    );
    return SizedBox(
      width: metrics.badgeSize + 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          _CountryBadge(
            countryCode: name == null ? null : code,
            size: metrics.badgeSize,
            active: active,
            checking: checking,
            onRefresh: onRefresh,
          ),
          Text(name == null ? '—' : code!, style: DashboardText.label(context)),
          Tooltip(
            message: name ?? context.appLocalizations.unknown,
            child: Text(
              name ?? context.appLocalizations.unknown,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: DashboardText.label(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExitRow extends StatelessWidget {
  const _ExitRow({
    required this.info,
    required this.failed,
    required this.active,
    required this.metrics,
  });

  final IpInfo? info;
  final bool failed;
  final bool active;
  final _OutboundMetrics metrics;

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
    if (info != null) {
      return Tooltip(
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
      );
    }
    return failed
        ? Tooltip(
            message: appLocalizations.tapIconToRetry,
            child: Text(
              appLocalizations.serviceFailed,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(color: colorScheme.error),
            ),
          )
        : SkeletonText(width: 140, style: style);
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

class _IpDimensions extends StatelessWidget {
  const _IpDimensions({required this.quality, required this.loading});

  final IpQuality? quality;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final strings = context.appLocalizations;
    final quality = this.quality;
    final hasAccessEvidence = quality?.typeIsInferred == false;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Expanded(
          child: _IpDimension(
            label: strings.statusIpOrigin,
            value: strings.unknown,
            evidence: strings.statusOriginUnknownReason,
          ),
        ),
        Expanded(
          child: _IpDimension(
            label: strings.statusAccessType,
            value: hasAccessEvidence
                ? quality!.type.label(context)
                : strings.unknown,
            evidence: hasAccessEvidence
                ? strings.statusAccessSource(quality!.source.label)
                : strings.statusAccessUnverified,
            loading: loading,
          ),
        ),
        const Expanded(child: _NetworkQualityDimension()),
      ],
    );
  }
}

class _NetworkQualityDimension extends ConsumerWidget {
  const _NetworkQualityDimension();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(networkQualityProvider);
    final report = state.reportFor(ref.watch(routeTrackerProvider));
    final l10n = context.appLocalizations;
    return _IpDimension(
      label: l10n.statusNetworkQuality,
      value: (report?.grade ?? NetworkQualityGrade.unknown).label,
      evidence: report == null
          ? l10n.statusQualityUnknownReason
          : '${l10n.qualityScope}\n$networkQualityUrl · ${report.completed}/$networkQualityRounds · ${report.medianMs?.toStringAsFixed(1) ?? "—"} ms',
      loading: state.running,
      onPressed: () => showNetworkQualitySheet(context),
    );
  }
}

class _IpDimension extends StatelessWidget {
  const _IpDimension({
    required this.label,
    required this.value,
    required this.evidence,
    this.loading = false,
    this.onPressed,
  });

  final VoidCallback? onPressed;
  final String label;
  final String value;
  final String evidence;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final dimension = Tooltip(
      message: '$label: $value\n$evidence',
      child: Semantics(
        label: '$label: $value. $evidence',
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: DashboardDensityScope.of(context).isDesktop ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption2
                  .of(context)
                  .copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
            if (loading)
              SkeletonText(width: 48, style: DashboardText.label(context))
            else
              Text(
                value,
                maxLines: DashboardDensityScope.of(context).isDesktop ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.caption1.of(context, emphasized: true),
              ),
          ],
        ),
      ),
    );
    if (onPressed == null) return dimension;
    return FocusRing(
      shape: AppShape.xs,
      standsOff: true,
      child: InkWell(
        customBorder: AppShape.xs,
        onTap: onPressed,
        child: dimension,
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
      _turns.stop();
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

  final bool inline;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final organization = switch (quality) {
      IpQuality(organization: final name?) when name.isNotEmpty => name,
      IpQuality(asn: final asn?) => 'AS$asn',
      _ => null,
    };
    final runTime = active ? const _RunTimeValue() : const _Placeholder();
    final network = organization != null
        ? _CellText(organization)
        : loading
        ? SkeletonText(width: 96, style: _cellStyle(context))
        : const _Placeholder();
    if (inline) {
      return Row(
        spacing: gap,
        children: [
          Semantics(
            label: appLocalizations.runTime,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Tooltip(
                  message: appLocalizations.runTime,
                  child: GlyphIcon(
                    AppGlyphs.clock,
                    size: 12,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
                runTime,
              ],
            ),
          ),
          Expanded(
            child: Semantics(
              label: appLocalizations.ipOrganization,
              child: network,
            ),
          ),
        ],
      );
    }
    return Row(
      spacing: gap,
      children: [
        Flexible(
          child: _Cell(label: appLocalizations.runTime, value: runTime),
        ),
        Flexible(
          child: _Cell(label: appLocalizations.ipOrganization, value: network),
        ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DashboardText.label(context),
        ),
        const SizedBox(height: 2),
        value,
      ],
    );
  }
}

TextStyle _cellStyle(BuildContext context) =>
    AppTextStyle.caption1.of(context, emphasized: true).toTabular;

class _CellText extends StatelessWidget {
  const _CellText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: text,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _cellStyle(context),
      ),
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

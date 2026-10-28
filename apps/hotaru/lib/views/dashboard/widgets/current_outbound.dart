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
      child: _DesktopStatusBody(
        info: ipInfo,
        failed: failed,
        loading: loading,
        checking: phase == ProbePhase.probing || qualityLoading,
        quality: quality,
        active: isStart && !suspended,
        chipLabel: chipLabel,
        chipTone: chipTone,
        chipDot: isStart,
        onRefresh: () => _refresh(ipInfo?.ip),
        compact: density.isCompact,
        toggle: _StartToggle(
          size: 48,
          enabled: hasProfile,
          running: isStart,
          suspended: suspended,
        ),
      ),
    );
  }
}

class _DesktopStatusBody extends StatelessWidget {
  const _DesktopStatusBody({
    required this.info,
    required this.failed,
    required this.loading,
    required this.checking,
    required this.quality,
    required this.active,
    required this.chipLabel,
    required this.chipTone,
    required this.chipDot,
    required this.onRefresh,
    required this.compact,
    required this.toggle,
  });

  final IpInfo? info;
  final bool failed;
  final bool loading;
  final bool checking;
  final IpQuality? quality;
  final bool active;
  final String chipLabel;
  final DashboardChipTone chipTone;
  final bool chipDot;
  final VoidCallback onRefresh;
  final bool compact;
  final Widget toggle;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final ipStyle = DashboardText.figure(
      context,
      !DashboardDensityScope.of(context).isDesktop
          ? AppTextStyle.title3
          : compact
          ? AppTextStyle.title2
          : AppTextStyle.title1,
      color: active ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
    ).copyWith(letterSpacing: 0);
    final info = this.info;
    final compactSkeleton = DashboardDensityScope.of(context).isDesktop
        ? 140.0
        : 96.0;
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
                child: _IpText(ip: info.ip, style: ipStyle),
              ),
            ),
          )
        : failed
        ? Text(
            appLocalizations.serviceFailed,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ipStyle.copyWith(color: colorScheme.error),
          )
        : SkeletonText(width: compactSkeleton, style: ipStyle);
    return Padding(
      padding: const EdgeInsets.all(DashboardLayoutTokens.padding),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 480;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                spacing: narrow ? 8 : 12,
                children: [
                  _FlagColumn(
                    countryCode: info?.countryCode,
                    checking: checking,
                    onRefresh: onRefresh,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        ip,
                        if (failed)
                          Text(
                            appLocalizations.tapIconToRetry,
                            style: DashboardText.label(context),
                          )
                        else
                          _IpChips(
                            quality: quality,
                            loading: loading,
                            large: false,
                            ip: info?.ip,
                          ),
                      ],
                    ),
                  ),
                  SizedBox(width: narrow ? 48 : 72, child: toggle),
                ],
              ),
              const SizedBox(height: 4),
              _MetaLine(
                quality: quality,
                loading: loading,
                active: active,
                stateLabel: chipLabel,
                stateTone: chipTone,
                stateDot: chipDot,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MetaLine extends ConsumerWidget {
  const _MetaLine({
    required this.quality,
    required this.loading,
    required this.active,
    this.stateLabel,
    this.stateTone = DashboardChipTone.idle,
    this.stateDot = false,
  });

  final IpQuality? quality;
  final bool loading;
  final bool active;

  final String? stateLabel;
  final DashboardChipTone stateTone;
  final bool stateDot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final organization = switch (quality) {
      IpQuality(organization: final name?) when name.isNotEmpty => name,
      IpQuality(asn: final asn?) => 'AS$asn',
      _ => null,
    };
    final runTime = active ? getTimeText(ref.watch(runTimeProvider)) : '—';
    final labelStyle = DashboardText.label(context);
    final colors = DashboardColors.of(context);
    final stateColor = switch (stateTone) {
      DashboardChipTone.ok => colors.onOkContainer,
      DashboardChipTone.warn => colors.onWarnContainer,
      DashboardChipTone.idle => context.colorScheme.onSurfaceVariant,
    };
    return Wrap(
      spacing: 8,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (stateLabel != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              if (stateDot)
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: stateColor,
                    shape: AppShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 6),
                ),
              Text(stateLabel!, style: labelStyle.copyWith(color: stateColor)),
            ],
          ),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '${appLocalizations.runTime} ', style: labelStyle),
              TextSpan(text: runTime, style: labelStyle.toTabular),
            ],
          ),
        ),
        if (loading && organization == null)
          SkeletonText(width: 84, style: labelStyle)
        else if (organization != null)
          Text(organization, style: labelStyle),
      ],
    );
  }
}

/// The flag badge at the status card's left edge: the SVG flag with the
/// country code and its localized name stacked under it. Tapping it
/// checks the exit again, like the badge it replaces.
class _FlagColumn extends StatelessWidget {
  const _FlagColumn({
    required this.countryCode,
    required this.checking,
    required this.onRefresh,
  });

  final String? countryCode;
  final bool checking;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final code = countryCode;
    final name = countryNameOf(
      code,
      Localizations.localeOf(context).languageCode,
    );
    final tooltip = context.appLocalizations.retry;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: !checking,
        label: tooltip,
        child: InkResponse(
          onTap: checking ? null : onRefresh,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          child: ElasticPress(
            enabled: !checking,
            child: SizedBox(
              width: 48,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FlagIcon(countryCode: code, width: 38),
                  const SizedBox(height: 5),
                  Text(
                    code?.toUpperCase() ?? '—',
                    maxLines: 1,
                    style: AppTextStyle.subheadline
                        .of(context, emphasized: true)
                        .toTabular,
                  ),
                  if (name != null)
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.caption1
                          .of(context)
                          .copyWith(
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
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

/// The status card's tag row, in the spec's fixed order: IP origin
/// (native or broadcast), access type, then the quality grade. A value
/// that has not been established reads unknown, never a guess.
class _IpChips extends ConsumerWidget {
  const _IpChips({
    required this.quality,
    required this.loading,
    required this.large,
    required this.ip,
  });

  final IpQuality? quality;
  final bool loading;
  final bool large;
  final String? ip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = this.quality;
    final height = _chipHeight(large);
    final ip = this.ip;
    final origin = ip == null ? null : ref.watch(ipOriginProvider(ip)).value;
    final unknown = context.appLocalizations.unknown;
    final children = <Widget>[
      if (ip != null)
        origin == null
            ? SkeletonPill(width: 56, height: height)
            : DashboardChip(label: origin.label(context), large: large),
      if (quality != null) ...[
        DashboardChip(label: quality.type.label(context), large: large),
        DashboardChip(
          label: quality.level.label(context),
          tone: switch (quality.level) {
            IpQualityLevel.good => DashboardChipTone.ok,
            IpQualityLevel.normal => DashboardChipTone.idle,
            IpQualityLevel.risky => DashboardChipTone.warn,
          },
          large: large,
        ),
      ] else if (loading)
        for (final width in _chipSkeletonWidths)
          SkeletonPill(width: width, height: height)
      else ...[
        DashboardChip(label: unknown, large: large),
        DashboardChip(label: unknown, large: large),
      ],
    ];
    return Wrap(spacing: 6, runSpacing: 4, children: children);
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
                            const Color(0xff1d5c40),
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
    canvas.drawPath(outline, Paint()..color = const Color(0xff123b2a));
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
              ? const [Color(0xff35d99a), Color(0xff1f9d74)]
              : const [Color(0xff2c4238), Color(0xff22352c)],
        ).createShader(Offset.zero & size),
    );
    canvas.restore();
    canvas.drawPath(
      outline,
      Paint()
        ..color = const Color(
          0xff7fe3b6,
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

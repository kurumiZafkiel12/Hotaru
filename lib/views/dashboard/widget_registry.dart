import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dashboard/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

extension DashboardWidgetView on DashboardWidget {
  Widget get card => switch (this) {
    DashboardWidget.currentOutbound => const CurrentOutboundCard(),
    DashboardWidget.networkSpeed => const NetworkSpeedCard(),
    DashboardWidget.outboundMode => const OutboundModeCard(),
    DashboardWidget.vpnButton => const VpnCard(),
    DashboardWidget.networkTakeover => const NetworkTakeoverCard(),
    DashboardWidget.serviceStatus => const ServiceStatusCard(),
    DashboardWidget.profiles => const ProfilesCard(),
    DashboardWidget.proxyGroups => const ProxyGroupsCard(),
    DashboardWidget.connectionStats => const ConnectionStatsCard(),
    DashboardWidget.intranetIp => const IntranetIpCard(),
    DashboardWidget.memoryInfo => const MemoryInfo(),
    DashboardWidget.speedTest => const SpeedTestShortcutCard(),
    DashboardWidget.connectionsTable => const ConnectionsTableCard(),
  };

  Glyph get glyph => switch (this) {
    DashboardWidget.currentOutbound => AppGlyphs.status,
    DashboardWidget.networkSpeed => AppGlyphs.speed,
    DashboardWidget.outboundMode => AppGlyphs.split,
    DashboardWidget.vpnButton => AppGlyphs.vpn,
    DashboardWidget.networkTakeover => AppGlyphs.shuffle,
    DashboardWidget.serviceStatus => AppGlyphs.verified,
    DashboardWidget.profiles => AppGlyphs.profiles,
    DashboardWidget.proxyGroups => AppGlyphs.layers,
    DashboardWidget.connectionStats => AppGlyphs.connections,
    DashboardWidget.intranetIp => AppGlyphs.devices,
    DashboardWidget.memoryInfo => AppGlyphs.memory,
    DashboardWidget.speedTest => AppGlyphs.speed,
    DashboardWidget.connectionsTable => AppGlyphs.connections,
  };

  String label(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return switch (this) {
      DashboardWidget.currentOutbound => appLocalizations.status,
      DashboardWidget.networkSpeed => appLocalizations.networkSpeed,
      DashboardWidget.outboundMode => appLocalizations.outboundMode,
      DashboardWidget.vpnButton => 'VPN',
      DashboardWidget.networkTakeover => appLocalizations.networkTakeover,
      DashboardWidget.serviceStatus => appLocalizations.serviceStatus,
      DashboardWidget.profiles => appLocalizations.profile,
      DashboardWidget.proxyGroups => appLocalizations.proxyGroup,
      DashboardWidget.connectionStats => appLocalizations.connectionStats,
      DashboardWidget.intranetIp => appLocalizations.intranetIP,
      DashboardWidget.memoryInfo => appLocalizations.memoryInfo,
      DashboardWidget.speedTest => appLocalizations.speedTest,
      DashboardWidget.connectionsTable => appLocalizations.connections,
    };
  }

  DashboardSpanSpec get spanSpec => switch (this) {
    DashboardWidget.currentOutbound => const DashboardSpanSpec(
      widths: [4],
      defaultWidth: 4,
      heights: [DashboardCardHeight.hero],
      defaultHeight: DashboardCardHeight.hero,
    ),
    DashboardWidget.networkSpeed => const DashboardSpanSpec(
      widths: [2, 3, 4],
      defaultWidth: 2,
      heights: [DashboardCardHeight.tall],
      defaultHeight: DashboardCardHeight.tall,
    ),
    DashboardWidget.outboundMode => const DashboardSpanSpec(
      widths: [2, 3, 4],
      defaultWidth: 2,
      heights: [DashboardCardHeight.middle, DashboardCardHeight.tall],
      defaultHeight: DashboardCardHeight.middle,
    ),
    DashboardWidget.vpnButton => const DashboardSpanSpec(
      widths: [2, 3, 4],
      defaultWidth: 2,
      heights: [DashboardCardHeight.summary],
      defaultHeight: DashboardCardHeight.summary,
    ),
    DashboardWidget.networkTakeover => const DashboardSpanSpec(
      widths: [2, 3, 4],
      defaultWidth: 2,
      heights: [DashboardCardHeight.large, DashboardCardHeight.tall],
      defaultHeight: DashboardCardHeight.large,
    ),
    DashboardWidget.serviceStatus => const DashboardSpanSpec(
      widths: [1, 2],
      defaultWidth: 1,
      heights: [DashboardCardHeight.middle],
      defaultHeight: DashboardCardHeight.middle,
    ),
    DashboardWidget.profiles => const DashboardSpanSpec(
      widths: [1, 2],
      defaultWidth: 1,
      heights: [DashboardCardHeight.middle],
      defaultHeight: DashboardCardHeight.middle,
    ),
    DashboardWidget.proxyGroups => const DashboardSpanSpec(
      widths: [2, 3, 4],
      defaultWidth: 2,
      heights: [
        DashboardCardHeight.summary,
        DashboardCardHeight.middle,
        DashboardCardHeight.tall,
      ],
      defaultHeight: DashboardCardHeight.summary,
    ),
    DashboardWidget.connectionStats => const DashboardSpanSpec(
      widths: [2, 3, 4],
      defaultWidth: 2,
      heights: [DashboardCardHeight.summary, DashboardCardHeight.middle],
      defaultHeight: DashboardCardHeight.summary,
    ),
    DashboardWidget.intranetIp => const DashboardSpanSpec(
      widths: [1, 2],
      defaultWidth: 1,
      heights: [DashboardCardHeight.middle],
      defaultHeight: DashboardCardHeight.middle,
    ),
    DashboardWidget.memoryInfo => const DashboardSpanSpec(
      widths: [1, 2],
      defaultWidth: 1,
      heights: [DashboardCardHeight.middle],
      defaultHeight: DashboardCardHeight.middle,
    ),
    DashboardWidget.speedTest => const DashboardSpanSpec(
      widths: [2, 3, 4],
      defaultWidth: 2,
      heights: [DashboardCardHeight.summary, DashboardCardHeight.middle],
      defaultHeight: DashboardCardHeight.summary,
    ),
    DashboardWidget.connectionsTable => const DashboardSpanSpec(
      widths: [4],
      defaultWidth: 4,
      heights: [DashboardCardHeight.tall, DashboardCardHeight.grande],
      defaultHeight: DashboardCardHeight.tall,
    ),
  };

  String? description(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return switch (this) {
      DashboardWidget.currentOutbound => appLocalizations.currentOutboundDesc,
      DashboardWidget.connectionStats => appLocalizations.connectionStatsDesc,
      DashboardWidget.memoryInfo => appLocalizations.memoryInfoDesc,
      _ => null,
    };
  }

  /// It holds the start button, which has nowhere else to go.
  bool get removable => this != DashboardWidget.currentOutbound;

  /// Decodes the persisted size code (width * 10 + height band index).
  DashboardSpan spanFrom(Map<String, int> saved) {
    final spec = spanSpec;
    final code = saved[name];
    if (code == null) {
      return DashboardSpan(
        width: spec.defaultWidth,
        height: spec.defaultHeight,
      );
    }
    final width = code ~/ 10;
    final heightIndex = code % 10;
    return DashboardSpan(
      width: spec.widths.contains(width) ? width : spec.defaultWidth,
      height: heightIndex >= 0 && heightIndex < spec.heights.length
          ? spec.heights[heightIndex]
          : spec.defaultHeight,
    );
  }

  int spanCode(DashboardSpan span) =>
      span.width * 10 + spanSpec.heights.indexOf(span.height);
}

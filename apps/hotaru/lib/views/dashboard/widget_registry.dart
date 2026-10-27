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

  /// The card's fixed height band in the desktop grid.
  DashboardBand get band => switch (this) {
    DashboardWidget.currentOutbound => DashboardBand.low,
    DashboardWidget.networkSpeed => DashboardBand.mid,
    DashboardWidget.outboundMode => DashboardBand.low,
    DashboardWidget.vpnButton => DashboardBand.low,
    DashboardWidget.networkTakeover => DashboardBand.high,
    DashboardWidget.serviceStatus => DashboardBand.mid,
    DashboardWidget.profiles => DashboardBand.mid,
    DashboardWidget.proxyGroups => DashboardBand.high,
    DashboardWidget.connectionStats => DashboardBand.low,
    DashboardWidget.intranetIp => DashboardBand.low,
    DashboardWidget.memoryInfo => DashboardBand.mid,
    DashboardWidget.speedTest => DashboardBand.mid,
    DashboardWidget.connectionsTable => DashboardBand.high,
  };

  /// The card's fixed width in grid columns on a full-width grid; the
  /// placement clamps it to narrower grids.
  int get span => switch (this) {
    DashboardWidget.currentOutbound => 2,
    DashboardWidget.networkSpeed => 2,
    DashboardWidget.outboundMode => 2,
    DashboardWidget.vpnButton => 2,
    DashboardWidget.networkTakeover => 2,
    DashboardWidget.serviceStatus => 1,
    DashboardWidget.profiles => 1,
    DashboardWidget.proxyGroups => 2,
    DashboardWidget.connectionStats => 4,
    DashboardWidget.intranetIp => 1,
    DashboardWidget.memoryInfo => 1,
    DashboardWidget.speedTest => 2,
    DashboardWidget.connectionsTable => 4,
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
}

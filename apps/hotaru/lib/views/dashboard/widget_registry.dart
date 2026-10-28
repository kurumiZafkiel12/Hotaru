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

  /// The column span and fixed height band of each desktop component.
  DashboardTier get tier => switch (this) {
    DashboardWidget.currentOutbound => DashboardTier.mid,
    DashboardWidget.networkSpeed => DashboardTier.mid,
    DashboardWidget.outboundMode => DashboardTier.short,
    DashboardWidget.vpnButton => DashboardTier.short,
    DashboardWidget.networkTakeover => DashboardTier.short,
    DashboardWidget.serviceStatus => DashboardTier.narrow,
    DashboardWidget.profiles => DashboardTier.narrow,
    DashboardWidget.proxyGroups => DashboardTier.tall,
    DashboardWidget.connectionStats => DashboardTier.small,
    DashboardWidget.intranetIp => DashboardTier.narrow,
    DashboardWidget.memoryInfo => DashboardTier.narrow,
    DashboardWidget.speedTest => DashboardTier.mid,
    DashboardWidget.connectionsTable => DashboardTier.tall,
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

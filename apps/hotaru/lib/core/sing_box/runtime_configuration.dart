import 'dart:isolate';

import '../adapter.dart';
import '../config/mode_outbounds.dart';
import '../config/profile.dart';
import '../routing_mode.dart';
import 'config_preparation.dart';

Future<AcceptedSingBoxConfig> prepareSingBoxRuntime({
  required AcceptedSingBoxConfig configuration,
  required bool enabled,
  required CoreRoutingMode mode,
  required List<CoreOutbound> outbounds,
  required bool preserveSelections,
}) async {
  final (:profile, :global) = await _runtimeData(
    configuration.profile,
    outbounds,
    preserveSelections,
    configuration.listeners.globalSelection,
  );
  final preparer = SingBoxConfigPreparer();
  final prepared = await preparer.prepare(
    profileId: configuration.profileId,
    import: () async => CoreConfigImportResult(profile: profile, issues: []),
    listeners: configuration.listeners.withRuntime(
      enabled: enabled,
      mode: mode,
      globalSelection: global,
    ),
  );
  if (prepared.status != SingBoxPreparationStatus.ready) {
    throw const CoreAdapterException('runtime_configuration_invalid');
  }
  return preparer.approve(prepared.candidate!);
}

Future<({CoreProfileSpec profile, String? global})> _runtimeData(
  CoreProfileSpec profile,
  List<CoreOutbound> outbounds,
  bool preserve,
  String? initialGlobal,
) => Isolate.run(() {
  if (!preserve) return (profile: profile, global: initialGlobal);
  final modes = CoreModeOutbounds(profile);
  final global = outbounds
      .where((entry) => entry.name == modes.global.tag)
      .firstOrNull
      ?.selected;
  final selected = {
    for (final entry in outbounds)
      if (entry.type.toLowerCase() == 'selector' && entry.selected != null)
        entry.name: entry.selected!,
  };
  final updated = CoreProfileSpec(
    nodes: profile.nodes,
    selectors: [
      for (final group in profile.selectors)
        CoreSelectorSpec(
          tag: group.tag,
          members: group.members,
          selected: group.strategy == CoreGroupStrategy.selector
              ? selected[group.tag] ?? group.selected
              : null,
          strategy: group.strategy,
          testUrl: group.testUrl,
          interval: group.interval,
          tolerance: group.tolerance,
        ),
    ],
    finalOutbound: profile.finalOutbound,
    rules: profile.rules,
    dns: profile.dns,
  );
  return (profile: updated, global: global);
});

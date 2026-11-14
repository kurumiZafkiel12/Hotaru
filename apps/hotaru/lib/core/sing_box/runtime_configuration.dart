import 'dart:isolate';

import '../adapter.dart';
import '../config/mode_outbounds.dart';
import '../config/profile.dart';
import '../config/runtime_options.dart';
import '../routing_mode.dart';
import 'config_preparation.dart';

Future<AcceptedSingBoxConfig> prepareSingBoxRuntime({
  required AcceptedSingBoxConfig configuration,
  required bool enabled,
  required CoreRoutingMode mode,
  required List<CoreOutbound> outbounds,
  required bool preserveSelections,
  CoreRuntimeOptions? runtime,
  CoreProfileSpec? replacementProfile,
  CoreListenerSpec? listeners,
  Object? applicationData,
}) async {
  final (:profile, :global) = await _runtimeData(
    replacementProfile ?? configuration.profile,
    outbounds,
    preserveSelections,
    configuration.listeners.globalSelection,
    runtime,
  );
  final preparer = SingBoxConfigPreparer();
  final prepared = await preparer.prepare(
    profileId: configuration.profileId,
    applicationData: applicationData ?? configuration.applicationData,
    import: () async => CoreConfigImportResult(profile: profile, issues: []),
    listeners: (listeners ?? configuration.listeners).withRuntime(
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
  CoreRuntimeOptions? runtime,
) => Isolate.run(() {
  if (!preserve && runtime == null) {
    return (profile: profile, global: initialGlobal);
  }
  final modes = CoreModeOutbounds(profile);
  final global = outbounds
      .where((entry) => entry.name == modes.global.tag)
      .firstOrNull
      ?.selected;
  final selected = {
    for (final entry in outbounds)
      if (preserve &&
          entry.type.toLowerCase() == 'selector' &&
          entry.selected != null)
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
              ? group.members.contains(selected[group.tag])
                    ? selected[group.tag]
                    : group.selected
              : null,
          strategy: group.strategy,
          testUrl: group.testUrl,
          interval: group.interval,
          tolerance: group.tolerance,
        ),
    ],
    finalOutbound: profile.finalOutbound,
    rules: profile.rules,
    ruleSets: profile.ruleSets,
    dns: profile.dns,
    runtime: runtime ?? profile.runtime,
  );
  return (
    profile: updated,
    global: modes.global.members.contains(preserve ? global : initialGlobal)
        ? preserve
              ? global
              : initialGlobal
        : modes.global.members.contains(initialGlobal)
        ? initialGlobal
        : null,
  );
});

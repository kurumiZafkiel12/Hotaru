import 'dart:isolate';

import '../../models/core.dart';
import '../config/application_settings.dart';
import '../config/clash_subscription.dart';
import '../config/mode_outbounds.dart';
import '../config/profile.dart';
import '../profile_documents.dart';
import 'config_preparation.dart';

final class SingBoxApplicationProfilePreparer {
  final String configPath;
  final ClashSubscriptionImporter Function(CoreApplicationSettings) importer;
  final Future<CoreListenerSpec> Function(
    CoreProfileSpec,
    CoreApplicationSettings,
  )
  listeners;
  final Future<bool> Function(List<CoreConfigIssue>) review;
  final SingBoxConfigPreparer _preparer = SingBoxConfigPreparer();
  int _revision = 0;
  bool _closed = false;

  SingBoxApplicationProfilePreparer({
    required this.configPath,
    required this.importer,
    required this.listeners,
    required this.review,
  });

  bool _current(int revision) => !_closed && revision == _revision;

  Future<AcceptedSingBoxConfig?> prepare(
    SetupParams params,
    int? profileId,
  ) async {
    if (_closed) throw StateError('Profile preparation is closed');
    final revision = ++_revision;
    _preparer.cancel();
    if (profileId != null && profileId < 0) {
      return _reject(revision, [
        const CoreConfigIssue(
          'invalid_profile_identity',
          'application.profileId',
        ),
      ]);
    }
    final SingBoxPreparationResult? prepared;
    try {
      prepared = await _readAndPrepare(params, profileId, revision);
    } on _ApplicationIssues catch (error) {
      return _reject(revision, error.issues);
    } catch (_) {
      return _reject(revision, [
        const CoreConfigIssue('configuration_preparation_failed', 'document'),
      ]);
    }
    if (!_current(revision) ||
        prepared == null ||
        prepared.status == SingBoxPreparationStatus.superseded) {
      return null;
    }
    final candidate = prepared.candidate;
    if (candidate == null) return _reject(revision, prepared.issues);
    if (prepared.issues.isNotEmpty) {
      final approved = await review(prepared.issues);
      if (!_current(revision) || !approved) return null;
      return _preparer.approve(
        candidate,
        acknowledgment: _preparer.acknowledge(candidate),
      );
    }
    return _preparer.approve(candidate);
  }

  Future<SingBoxPreparationResult?> _readAndPrepare(
    SetupParams params,
    int? profileId,
    int revision,
  ) async {
    final base = params.base;
    final source = base == null
        ? await CoreProfileDocuments.readText(configPath)
        : await CoreProfileDocuments.build(base);
    if (!_current(revision)) return null;
    final projection = await CoreApplicationSettings.parse(
      source,
      skipCertVerify: params.skipCertVerify,
    );
    if (!_current(revision)) return null;
    final settings = projection.settings;
    if (settings == null) throw _ApplicationIssues(projection.issues);
    final imported = await importer(settings).import(settings.source);
    if (!_current(revision)) return null;
    final issues = [...projection.issues, ...imported.issues];
    final profile = imported.profile;
    if (profile == null ||
        issues.any(
          (issue) => issue.severity == CoreConfigIssueSeverity.error,
        )) {
      throw _ApplicationIssues(
        issues.isEmpty
            ? [const CoreConfigIssue('missing_profile', 'document')]
            : issues,
      );
    }
    final runtime = settings.runtime;
    final selected = params.selectedMap;
    final (:updated, :global) = await Isolate.run(() {
      final updated = CoreProfileSpec(
        nodes: profile.nodes,
        selectors: [
          for (final group in profile.selectors)
            CoreSelectorSpec(
              tag: group.tag,
              members: group.members,
              selected:
                  group.strategy == CoreGroupStrategy.selector &&
                      group.members.contains(selected[group.tag])
                  ? selected[group.tag]
                  : group.selected,
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
        runtime: runtime,
      );
      final modes = CoreModeOutbounds(updated);
      final saved = selected[modes.global.tag];
      return (
        updated: updated,
        global: modes.global.members.contains(saved) ? saved : null,
      );
    });
    if (!_current(revision)) return null;
    final bound = await listeners(updated, settings);
    if (!_current(revision)) return null;
    return _preparer.prepare(
      profileId: profileId,
      applicationData: settings,
      import: () async =>
          CoreConfigImportResult(profile: updated, issues: issues),
      listeners: bound.withRuntime(
        enabled: bound.inboundsEnabled,
        mode: settings.mode,
        globalSelection: global,
      ),
    );
  }

  Future<AcceptedSingBoxConfig?> _reject(
    int revision,
    List<CoreConfigIssue> issues,
  ) async {
    if (_current(revision)) await review(issues);
    return null;
  }

  void close() {
    _closed = true;
    _revision++;
    _preparer.cancel();
  }
}

final class _ApplicationIssues implements Exception {
  final List<CoreConfigIssue> issues;

  const _ApplicationIssues(this.issues);
}

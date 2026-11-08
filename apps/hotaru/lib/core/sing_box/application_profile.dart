import 'dart:async';
import 'dart:isolate';

import '../../models/core.dart';
import '../adapter.dart';
import '../config/application_settings.dart';
import '../config/clash_subscription.dart';
import '../config/mode_outbounds.dart';
import '../config/profile.dart';
import '../profile_documents.dart';
import 'config_preparation.dart';
import 'runtime_configuration.dart';

final class SingBoxApplicationProfilePreparer {
  final String configPath;
  final Map<String, String> providerFiles;
  final ClashSubscriptionImporter Function(CoreApplicationSettings) importer;
  final Future<CoreListenerSpec> Function(
    CoreProfileSpec,
    CoreApplicationSettings,
  )
  listeners;
  final Future<bool> Function(List<CoreConfigIssue>) review;
  final ClashSubscriptionImporter Function(
    CoreApplicationSettings,
    Set<String>,
  )?
  refreshImporter;
  Completer<CoreConfigImportResult?>? _refreshCancellation;
  final SingBoxConfigPreparer _preparer = SingBoxConfigPreparer();
  int _revision = 0;
  bool _closed = false;
  Completer<bool>? _reviewCancellation;

  SingBoxApplicationProfilePreparer({
    required this.configPath,
    required this.importer,
    required this.listeners,
    required this.review,
    this.refreshImporter,
    Map<String, String> providerFiles = const {},
  }) : providerFiles = Map.unmodifiable(providerFiles);

  bool _current(int revision) => !_closed && revision == _revision;

  Future<AcceptedSingBoxConfig?> prepare(
    SetupParams params,
    int? profileId,
  ) async {
    if (_closed) throw StateError('Profile preparation is closed');
    final revision = ++_revision;
    _cancelReview();
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
      final approved = await _requestReview(prepared.issues, revision);
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
      authorizedProviderFiles: providerFiles,
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
      applicationData: settings.withProviders(
        imported.providers,
        importIssues: imported.issues,
      ),
      import: () async =>
          CoreConfigImportResult(profile: updated, issues: issues),
      listeners: bound.withRuntime(
        enabled: bound.inboundsEnabled,
        mode: settings.mode,
        globalSelection: global,
      ),
    );
  }

  Future<AcceptedSingBoxConfig?> update(
    AcceptedSingBoxConfig configuration,
    List<CoreOutbound> outbounds,
    UpdateParams params,
  ) async {
    if (_closed) throw StateError('Profile preparation is closed');
    final revision = ++_revision;
    _cancelReview();
    _preparer.cancel();
    final previous = configuration.applicationData;
    if (previous is! CoreApplicationSettings) {
      throw const CoreAdapterException('application_settings_unavailable');
    }
    final projection = await previous.updated(
      params.toJson(),
      skipCertVerify: params.skipCertVerify,
    );
    if (!_current(revision)) return null;
    final settings = projection.settings;
    if (settings == null) return _reject(revision, projection.issues);
    final newIssues = projection.issues
        .where(
          (issue) => !previous.issues.any(
            (old) =>
                old.code == issue.code &&
                old.path == issue.path &&
                old.severity == issue.severity,
          ),
        )
        .toList();
    if (newIssues.isNotEmpty) {
      final approved = await _requestReview(newIssues, revision);
      if (!_current(revision) || !approved) return null;
    }
    final bound = await listeners(configuration.profile, settings);
    if (!_current(revision)) return null;
    final updated = await prepareSingBoxRuntime(
      configuration: configuration,
      enabled: configuration.listeners.inboundsEnabled,
      mode: settings.mode,
      outbounds: outbounds,
      preserveSelections: true,
      runtime: settings.runtime,
      listeners: bound,
      applicationData: settings,
    );
    return _current(revision) ? updated : null;
  }

  Future<AcceptedSingBoxConfig?> refresh(
    AcceptedSingBoxConfig configuration,
    List<CoreOutbound> outbounds,
    String providerName,
  ) async {
    if (_closed) throw StateError('Profile preparation is closed');
    final settings = configuration.applicationData;
    if (settings is! CoreApplicationSettings ||
        !settings.providers.any((info) => info.name == providerName)) {
      throw const CoreAdapterException('provider_not_found');
    }
    final revision = ++_revision;
    _cancelReview();
    _preparer.cancel();
    final cancellation = Completer<CoreConfigImportResult?>();
    _refreshCancellation = cancellation;
    final CoreConfigImportResult? imported;
    try {
      final loader =
          refreshImporter?.call(settings, {providerName}) ?? importer(settings);
      imported = await Future.any([
        loader.import(settings.source),
        cancellation.future,
      ]);
    } finally {
      if (identical(_refreshCancellation, cancellation)) {
        _refreshCancellation = null;
      }
    }
    if (!_current(revision) || imported == null) return null;
    final profile = imported.profile;
    if (profile == null ||
        imported.issues.any(
          (issue) => issue.severity == CoreConfigIssueSeverity.error,
        )) {
      return _reject(revision, imported.issues);
    }
    final newIssues = imported.issues
        .where(
          (issue) => !settings.importIssues.any(
            (old) =>
                old.code == issue.code &&
                old.path == issue.path &&
                old.severity == issue.severity,
          ),
        )
        .toList();
    if (newIssues.isNotEmpty) {
      final approved = await _requestReview(newIssues, revision);
      if (!_current(revision) || !approved) return null;
    }
    final bound = await listeners(profile, settings);
    if (!_current(revision)) return null;
    final updated = await prepareSingBoxRuntime(
      configuration: configuration,
      replacementProfile: profile,
      enabled: configuration.listeners.inboundsEnabled,
      mode: settings.mode,
      outbounds: outbounds,
      preserveSelections: true,
      runtime: settings.runtime,
      listeners: bound,
      applicationData: settings.withProviders(
        imported.providers,
        importIssues: imported.issues,
      ),
    );
    return _current(revision) ? updated : null;
  }

  Future<AcceptedSingBoxConfig?> _reject(
    int revision,
    List<CoreConfigIssue> issues,
  ) async {
    if (_current(revision)) await _requestReview(issues, revision);
    return null;
  }

  Future<bool> _requestReview(
    List<CoreConfigIssue> issues,
    int revision,
  ) async {
    if (!_current(revision)) return false;
    final cancellation = Completer<bool>();
    _reviewCancellation = cancellation;
    try {
      return await Future.any([review(issues), cancellation.future]);
    } finally {
      if (identical(_reviewCancellation, cancellation)) {
        _reviewCancellation = null;
      }
    }
  }

  void _cancelReview() {
    final refresh = _refreshCancellation;
    _refreshCancellation = null;
    if (refresh != null && !refresh.isCompleted) refresh.complete(null);
    final cancellation = _reviewCancellation;
    _reviewCancellation = null;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete(false);
    }
  }

  void cancelPending() {
    _revision++;
    _cancelReview();
    _preparer.cancel();
  }

  void close() {
    _closed = true;
    _revision++;
    _cancelReview();
    _preparer.cancel();
  }
}

final class _ApplicationIssues implements Exception {
  final List<CoreConfigIssue> issues;

  const _ApplicationIssues(this.issues);
}

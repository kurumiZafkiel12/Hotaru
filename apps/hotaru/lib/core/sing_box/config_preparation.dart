import 'dart:isolate';

import '../config/encoding.dart';
import '../config/profile.dart';
import 'bootstrap.dart';
import 'config_builder.dart';

enum SingBoxPreparationStatus { ready, invalid, superseded }

final class SingBoxConfigCandidate {
  final int revision;
  final List<CoreConfigIssue> warnings;
  final CoreListenerSpec _listeners;
  final SingBoxBootstrap _bootstrap;

  const SingBoxConfigCandidate._(
    this.revision,
    this.warnings,
    this._listeners,
    this._bootstrap,
  );

  int get bootstrapBytes => _bootstrap.length;
}

final class AcknowledgedSingBoxWarnings {
  final SingBoxConfigCandidate _candidate;

  const AcknowledgedSingBoxWarnings._(this._candidate);
}

final class AcceptedSingBoxConfig {
  final SingBoxConfigCandidate _candidate;

  const AcceptedSingBoxConfig._(this._candidate);

  CoreListenerSpec get listeners => _candidate._listeners;
  SingBoxBootstrap get bootstrap => _candidate._bootstrap;
}

final class SingBoxPreparationResult {
  final SingBoxPreparationStatus status;
  final SingBoxConfigCandidate? candidate;
  final List<CoreConfigIssue> issues;

  const SingBoxPreparationResult._(
    this.status, {
    this.candidate,
    this.issues = const [],
  });
}

final class SingBoxConfigPreparer {
  int _revision = 0;
  SingBoxConfigCandidate? _current;

  Future<SingBoxPreparationResult> prepare({
    required Future<CoreConfigImportResult> Function() import,
    required CoreListenerSpec listeners,
  }) async {
    final revision = ++_revision;
    _current = null;
    try {
      final imported = await import();
      if (revision != _revision) return _superseded();
      final data = await _prepareData(imported, listeners);
      if (revision != _revision) return _superseded();
      final bootstrap = data.bootstrap;
      if (bootstrap == null) {
        return SingBoxPreparationResult._(
          SingBoxPreparationStatus.invalid,
          issues: data.issues,
        );
      }
      final candidate = SingBoxConfigCandidate._(
        revision,
        data.issues,
        listeners,
        bootstrap,
      );
      _current = candidate;
      return SingBoxPreparationResult._(
        SingBoxPreparationStatus.ready,
        candidate: candidate,
        issues: data.issues,
      );
    } catch (_) {
      if (revision != _revision) return _superseded();
      return const SingBoxPreparationResult._(
        SingBoxPreparationStatus.invalid,
        issues: [
          CoreConfigIssue('configuration_preparation_failed', 'document'),
        ],
      );
    }
  }

  AcknowledgedSingBoxWarnings acknowledge(SingBoxConfigCandidate candidate) {
    _checkCurrent(candidate);
    return AcknowledgedSingBoxWarnings._(candidate);
  }

  AcceptedSingBoxConfig approve(
    SingBoxConfigCandidate candidate, {
    AcknowledgedSingBoxWarnings? acknowledgment,
  }) {
    _checkCurrent(candidate);
    if (candidate.warnings.isNotEmpty &&
        !identical(acknowledgment?._candidate, candidate)) {
      throw StateError(
        'Conversion warnings require acknowledgment for this candidate',
      );
    }
    return AcceptedSingBoxConfig._(candidate);
  }

  void _checkCurrent(SingBoxConfigCandidate candidate) {
    if (!identical(candidate, _current) || candidate.revision != _revision) {
      throw StateError('Configuration review is no longer current');
    }
  }

  void cancel() {
    _revision++;
    _current = null;
  }
}

SingBoxPreparationResult _superseded() =>
    const SingBoxPreparationResult._(SingBoxPreparationStatus.superseded);

final class _PreparedData {
  final List<CoreConfigIssue> issues;
  final SingBoxBootstrap? bootstrap;

  _PreparedData(List<CoreConfigIssue> issues, [this.bootstrap])
    : issues = List.unmodifiable(issues);
}

Future<_PreparedData> _prepareData(
  CoreConfigImportResult imported,
  CoreListenerSpec listeners,
) => Isolate.run(() async {
  final issues = [...imported.issues];
  if (_errors(issues)) return _PreparedData(issues);
  final profile = imported.profile;
  if (profile == null) {
    return _PreparedData([
      ...issues,
      const CoreConfigIssue('missing_profile', 'document'),
    ]);
  }
  try {
    final built = await SingBoxConfigBuilder().build(profile, listeners);
    issues.addAll(built.issues);
    final json = built.json;
    if (json == null || _errors(issues)) {
      if (!_errors(issues)) {
        issues.add(
          const CoreConfigIssue('configuration_build_failed', 'document'),
        );
      }
      return _PreparedData(issues);
    }
    final bootstrap = await SingBoxBootstrap.prepare(json);
    return _PreparedData(issues, bootstrap);
  } on CoreConfigSizeException {
    return _PreparedData([
      ...issues,
      const CoreConfigIssue('compiled_config_too_large', 'document'),
    ]);
  }
});

bool _errors(List<CoreConfigIssue> issues) =>
    issues.any((issue) => issue.severity == CoreConfigIssueSeverity.error);

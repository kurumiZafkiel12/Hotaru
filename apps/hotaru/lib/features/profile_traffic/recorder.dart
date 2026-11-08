import 'dart:async';

import '../../core/desktop/model.dart';
import '../../core/sing_box/desktop_core.dart';
import '../../core/telemetry.dart';

final class ProfileTrafficObservation {
  final int profileId;
  final String sessionId;
  final int upload;
  final int download;

  const ProfileTrafficObservation({
    required this.profileId,
    required this.sessionId,
    required this.upload,
    required this.download,
  });
}

final class ProfileTrafficRecorder {
  final SingBoxDesktopCore core;
  final Future<void> Function(ProfileTrafficObservation) persist;
  final void Function(Object, StackTrace) onError;
  late final StreamSubscription<DesktopCoreState> _subscription;
  late final Timer _timer;
  final Set<String> _attached = {};
  Future<void> _writes = Future.value();
  Future<void>? _polling;
  Future<void>? _closing;
  bool _closed = false;

  ProfileTrafficRecorder({
    required this.core,
    required this.persist,
    required this.onError,
    Duration interval = const Duration(seconds: 1),
  }) {
    if (interval <= Duration.zero) {
      throw ArgumentError('Positive sample interval required');
    }
    _subscription = core.lifecycle.states.listen(_observeState);
    _timer = Timer.periodic(interval, (_) => unawaited(sample()));
    _observeState(core.lifecycle.state);
  }

  void _observeState(DesktopCoreState state) {
    if (_closed || _closing != null || state is! DesktopCoreRunning) return;
    final id = state.session.sessionId;
    final lease = state.session.lease;
    final source = lease is CoreFinalTrafficSource
        ? lease as CoreFinalTrafficSource
        : null;
    final profileId = source?.profileId;
    if (source != null && profileId != null && _attached.add(id)) {
      unawaited(
        source.finalTraffic
            .then((totals) async {
              _attached.remove(id);
              if (_closed) return;
              if (totals == null) {
                onError(
                  StateError('Final traffic observation unavailable'),
                  StackTrace.current,
                );
                return;
              }
              await _save(
                ProfileTrafficObservation(
                  profileId: profileId,
                  sessionId: id,
                  upload: totals.upload,
                  download: totals.download,
                ),
              );
            })
            .catchError((Object error, StackTrace trace) {
              _attached.remove(id);
              if (!_closed) onError(error, trace);
            }),
      );
    }
    unawaited(sample());
  }

  Future<void> sample() =>
      _polling ??= _sample().whenComplete(() => _polling = null);

  Future<void> _sample() async {
    if (_closed || _closing != null) return;
    final state = core.lifecycle.state;
    final configuration = core.configuration;
    final profileId = configuration?.profileId;
    final adapter = core.adapter;
    if (state is! DesktopCoreRunning ||
        profileId == null ||
        adapter is! CoreTelemetry) {
      return;
    }
    final id = state.session.sessionId;
    bool current() {
      final now = core.lifecycle.state;
      return !_closed &&
          identical(core.configuration, configuration) &&
          now is DesktopCoreRunning &&
          now.session.sessionId == id;
    }

    try {
      final sample = await (adapter as CoreTelemetry).telemetry();
      if (!current()) return;
      await _save(
        ProfileTrafficObservation(
          profileId: profileId,
          sessionId: id,
          upload: sample.uploadTotal,
          download: sample.downloadTotal,
        ),
      );
    } catch (error, trace) {
      if (current()) onError(error, trace);
    }
  }

  Future<void> _save(ProfileTrafficObservation observation) {
    _writes = _writes.then((_) => persist(observation)).catchError(onError);
    return _writes;
  }

  Future<void> flush() async {
    await Future<void>.delayed(Duration.zero);
    await _writes;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _timer.cancel();
    await _subscription.cancel();
    await Future<void>.delayed(Duration.zero);
    _closed = true;
    await _writes;
  }
}

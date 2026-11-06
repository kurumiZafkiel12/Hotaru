import 'dart:async';

import 'model.dart';
import 'connection.dart';

abstract interface class DesktopCoreLifecycleController {
  DesktopCoreState get state;

  Stream<DesktopCoreState> get states;

  Stream<DesktopCoreFailure> get crashEvents;

  Future<CoreLifecycleResult> start();

  Future<CoreLifecycleResult> restart();

  Future<CoreLifecycleResult> stop();

  Future<CoreLifecycleResult> close();

  Future<DesktopCoreSession> waitUntilRunning(Duration timeout);
}

class DesktopCoreLaunchPlan {
  final DesktopCoreConnection Function() transportFactory;
  final DesktopCoreLauncherResolver launcherResolver;

  const DesktopCoreLaunchPlan({
    required this.transportFactory,
    required this.launcherResolver,
  });
}

final class _ConfigurationRecovered implements Exception {
  final DesktopCoreFailure failure;
  final DesktopCoreLaunchPlan rejectedPlan;

  const _ConfigurationRecovered(this.failure, this.rejectedPlan);
}

enum _LifecycleTarget { running, restarted, stopped, closed }

enum _LifecycleAchievement { runningExisting, runningFresh, idle, closed }

final class _LifecycleIntent {
  final int revision;
  final _LifecycleTarget target;
  final DesktopCoreLaunchPlan plan;

  const _LifecycleIntent(this.revision, this.target, this.plan);
}

final class _PendingLifecycleCommand {
  final _LifecycleIntent intent;
  final Completer<CoreLifecycleResult> completer =
      Completer<CoreLifecycleResult>();

  _PendingLifecycleCommand(this.intent);
}

final class _SessionDisconnect {
  final DesktopCoreSession session;
  final Completer<void> _completed = Completer<void>();

  _SessionDisconnect(this.session);

  Future<void> get future => _completed.future;

  bool get isCompleted => _completed.isCompleted;

  void record(int generation) {
    if (generation == session.connectionGeneration && !_completed.isCompleted) {
      _completed.complete();
    }
  }
}

final class _TransportConnectionWaiter {
  final Completer<void> _settled = Completer<void>();
  late final StreamSubscription<DesktopTransportEvent> _subscription;
  late final Timer _timer;
  TransportConnected? _connection;
  Object? _error;
  StackTrace? _stackTrace;

  _TransportConnectionWaiter(
    Stream<DesktopTransportEvent> events,
    Duration timeout,
  ) {
    _subscription = events.listen(
      (event) {
        switch (event) {
          case TransportConnected():
            if (!_settled.isCompleted) {
              _connection = event;
              _settled.complete();
            }
          case TransportFailed(:final error, :final stackTrace):
            if (!_settled.isCompleted) {
              _error = error;
              _stackTrace = stackTrace;
              _settled.complete();
            }
          case TransportReady() || TransportDisconnected():
            break;
        }
      },
      onDone: () {
        if (!_settled.isCompleted) {
          _error = StateError('Core transport closed before connection');
          _stackTrace = StackTrace.current;
          _settled.complete();
        }
      },
    );
    _timer = Timer(timeout, () {
      if (!_settled.isCompleted) {
        _error = TimeoutException(
          'Core transport connection timed out',
          timeout,
        );
        _stackTrace = StackTrace.current;
        _settled.complete();
      }
    });
  }

  Future<TransportConnected> get future async {
    await _settled.future;
    final error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
    }
    return _connection!;
  }

  Future<void> cancel() async {
    _timer.cancel();
    await _subscription.cancel();
  }
}

final class DesktopCoreLifecycle implements DesktopCoreLifecycleController {
  DesktopCoreLaunchPlan _activePlan;
  late DesktopCoreLaunchPlan _committedPlan;
  DesktopCoreLaunchPlan? _recoveryPlan;
  final DesktopCoreTimeouts timeouts;
  final String Function() sessionIdFactory;
  final bool verifyPeerPid;
  final DesktopCoreConnectionBinding _transport;

  final StreamController<DesktopCoreState> _stateController =
      StreamController<DesktopCoreState>.broadcast();
  final StreamController<DesktopCoreFailure> _crashController =
      StreamController<DesktopCoreFailure>.broadcast();
  final List<_PendingLifecycleCommand> _pending = [];

  late final StreamSubscription<DesktopTransportEvent> _transportSubscription;
  DesktopCoreState _state = const DesktopCoreIdle();
  DesktopCoreSession? _session;
  _SessionDisconnect? _sessionDisconnect;
  Future<void>? _worker;
  Future<void>? _unexpectedDisconnectOperation;
  CoreProcessLease? _unconfirmedLease;
  Future<CoreLifecycleResult>? _closeResult;
  int _revision = 0;
  late _LifecycleIntent _desired;
  Completer<void> _intentChanged = Completer<void>();
  bool _terminalRequested = false;

  factory DesktopCoreLifecycle({
    required DesktopCoreConnection Function() transportFactory,
    required DesktopCoreLauncherResolver launcherResolver,
    DesktopCoreTimeouts timeouts = const DesktopCoreTimeouts(),
    String Function()? sessionIdFactory,
    bool verifyPeerPid = false,
  }) {
    return DesktopCoreLifecycle.withConnection(
      transportFactory: transportFactory,
      launcherResolver: launcherResolver,
      timeouts: timeouts,
      sessionIdFactory: sessionIdFactory ?? createCoreSessionId,
      verifyPeerPid: verifyPeerPid,
      connection: DesktopCoreConnectionBinding(transportFactory()),
    );
  }

  factory DesktopCoreLifecycle.withPlan({
    required DesktopCoreLaunchPlan plan,
    DesktopCoreTimeouts timeouts = const DesktopCoreTimeouts(),
    String Function()? sessionIdFactory,
    bool verifyPeerPid = false,
  }) => DesktopCoreLifecycle._(
    plan: plan,
    timeouts: timeouts,
    sessionIdFactory: sessionIdFactory ?? createCoreSessionId,
    verifyPeerPid: verifyPeerPid,
    connection: DesktopCoreConnectionBinding(plan.transportFactory()),
  );

  factory DesktopCoreLifecycle.withConnection({
    required DesktopCoreConnection Function() transportFactory,
    required DesktopCoreLauncherResolver launcherResolver,
    required DesktopCoreTimeouts timeouts,
    required String Function() sessionIdFactory,
    required bool verifyPeerPid,
    required DesktopCoreConnectionBinding connection,
  }) => DesktopCoreLifecycle._(
    plan: DesktopCoreLaunchPlan(
      transportFactory: transportFactory,
      launcherResolver: launcherResolver,
    ),
    timeouts: timeouts,
    sessionIdFactory: sessionIdFactory,
    verifyPeerPid: verifyPeerPid,
    connection: connection,
  );

  DesktopCoreLifecycle._({
    required DesktopCoreLaunchPlan plan,
    required this.timeouts,
    required this.sessionIdFactory,
    required this.verifyPeerPid,
    required DesktopCoreConnectionBinding connection,
  }) : _transport = connection,
       _activePlan = plan {
    _committedPlan = _activePlan;
    _desired = _LifecycleIntent(0, _LifecycleTarget.stopped, _committedPlan);
    _transportSubscription = _transport.events.listen(_handleTransportEvent);
  }

  DesktopCoreLaunchPlan get activePlan => _activePlan;
  DesktopCoreLaunchPlan get committedPlan => _committedPlan;

  Future<CoreLifecycleResult> applyConfiguration(DesktopCoreLaunchPlan plan) =>
      _submit(_LifecycleTarget.restarted, plan: plan);

  @override
  DesktopCoreState get state => _state;

  @override
  Stream<DesktopCoreState> get states => _stateController.stream;

  @override
  Stream<DesktopCoreFailure> get crashEvents => _crashController.stream;

  @override
  Future<CoreLifecycleResult> start() => _submit(_LifecycleTarget.running);

  @override
  Future<CoreLifecycleResult> restart() => _submit(_LifecycleTarget.restarted);

  @override
  Future<CoreLifecycleResult> stop() => _submit(_LifecycleTarget.stopped);

  @override
  Future<CoreLifecycleResult> close() {
    final closeResult = _closeResult;
    if (closeResult != null) {
      return closeResult;
    }
    final result = _submit(_LifecycleTarget.closed);
    _closeResult = result;
    return result;
  }

  Future<CoreLifecycleResult> _submit(
    _LifecycleTarget target, {
    DesktopCoreLaunchPlan? plan,
  }) {
    if (_terminalRequested) {
      return Future.error(
        DesktopCoreFailure(
          code: 'lifecycle_closed',
          phase: DesktopCorePhase.closed,
          revision: _revision,
        ),
      );
    }
    if (target == _LifecycleTarget.closed) {
      _terminalRequested = true;
    }
    if (target == _LifecycleTarget.stopped ||
        target == _LifecycleTarget.closed) {
      _recoveryPlan = null;
    }
    final intent = _LifecycleIntent(
      ++_revision,
      target,
      plan ?? _committedPlan,
    );
    final command = _PendingLifecycleCommand(intent);
    _pending.add(command);
    _desired = intent;
    final changed = _intentChanged;
    _intentChanged = Completer<void>();
    if (!changed.isCompleted) {
      changed.complete();
    }
    _ensureWorker();
    return command.completer.future;
  }

  void _ensureWorker() {
    if (_worker != null) {
      return;
    }
    late final Future<void> worker;
    worker = _runWorker().whenComplete(() {
      if (identical(_worker, worker)) {
        _worker = null;
      }
      if (_pending.isNotEmpty) {
        _ensureWorker();
      }
    });
    _worker = worker;
  }

  Future<void> _runWorker() async {
    while (_pending.isNotEmpty) {
      final recovery = _unexpectedDisconnectOperation;
      if (recovery != null) {
        await recovery;
      }
      final intent = _desired;
      try {
        final achievement = await _reconcile(intent);
        final settled = _desired;
        if (!_satisfies(achievement, settled.target) ||
            (_wantsRunning && !identical(_activePlan, settled.plan))) {
          continue;
        }
        _completeCommands(settled);
      } catch (error, stackTrace) {
        if (error is _ConfigurationRecovered) {
          _failCommands(
            error.failure.revision,
            error.failure,
            rejectedPlan: error.rejectedPlan,
          );
          continue;
        }
        final failure = error is DesktopCoreFailure
            ? error
            : _failure(
                code: 'lifecycle_error',
                phase: _state.phase,
                revision: intent.revision,
                cause: error,
                stackTrace: stackTrace,
              );
        final desired = _desired;
        if (desired.revision != intent.revision) {
          if (desired.target != _LifecycleTarget.closed) {
            _failCommands(intent.revision, failure);
          }
          continue;
        }
        _publish(DesktopCoreFailed(failure));
        _failCommands(intent.revision, failure);
      }
    }
  }

  Future<_LifecycleAchievement> _reconcile(_LifecycleIntent intent) async {
    final unconfirmedLease = _unconfirmedLease;
    if (unconfirmedLease != null) {
      await _stopUnconfirmedLease(
        unconfirmedLease,
        allowFailure: intent.target == _LifecycleTarget.closed,
      );
    }
    switch (intent.target) {
      case _LifecycleTarget.running:
      case _LifecycleTarget.restarted:
        final session = _session;
        if (session != null &&
            _state is DesktopCoreRunning &&
            intent.target == _LifecycleTarget.running &&
            identical(_activePlan, intent.plan)) {
          return _LifecycleAchievement.runningExisting;
        }
        if (session != null && !identical(_committedPlan, intent.plan)) {
          _recoveryPlan ??= _committedPlan;
        }
        if (session != null) {
          await _stopSession(
            session,
            intent.revision,
            allowUnconfirmedExit: _terminalRequested,
          );
        }
        if (!_wantsPlan(intent.plan)) return _abandonedStart();
        try {
          if (!identical(_activePlan, intent.plan)) {
            await _selectPlan(intent.plan);
          }
          return await _startForIntent(intent);
        } catch (error) {
          final previous = _recoveryPlan;
          if (previous == null ||
              identical(previous, intent.plan) ||
              !_wantsPlan(intent.plan)) {
            rethrow;
          }
          final unconfirmed = _unconfirmedLease;
          if (unconfirmed != null) {
            await _stopUnconfirmedLease(unconfirmed, allowFailure: false);
          }
          if (!_wantsPlan(intent.plan)) return _abandonedStart();
          final revision = _desired.revision;
          final restored = _LifecycleIntent(
            revision,
            _LifecycleTarget.restarted,
            previous,
          );
          _desired = restored;
          await _selectPlan(previous);
          if (!await _startSession(restored)) return _abandonedStart();
          _recoveryPlan = null;
          throw _ConfigurationRecovered(
            DesktopCoreFailure(
              code: 'configuration_rejected_previous_restored',
              phase: DesktopCorePhase.running,
              revision: revision,
              cause: error is DesktopCoreFailure ? error.code : 'start_failed',
            ),
            intent.plan,
          );
        }
      case _LifecycleTarget.stopped:
        final session = _session;
        if (session != null) {
          await _stopSession(
            session,
            intent.revision,
            allowUnconfirmedExit: false,
          );
        }
        if (_desired.target == _LifecycleTarget.stopped) {
          _publish(const DesktopCoreIdle());
        }
        return _LifecycleAchievement.idle;
      case _LifecycleTarget.closed:
        final session = _session;
        if (session != null) {
          await _stopSession(
            session,
            intent.revision,
            allowUnconfirmedExit: true,
          );
        }
        await _transportSubscription.cancel();
        await _transport.close();
        _publish(DesktopCoreClosed(intent.revision));
        await _stateController.close();
        await _crashController.close();
        return _LifecycleAchievement.closed;
    }
  }

  bool get _wantsRunning {
    return _desired.target == _LifecycleTarget.running ||
        _desired.target == _LifecycleTarget.restarted;
  }

  Future<void> _selectPlan(DesktopCoreLaunchPlan plan) async {
    if (identical(_activePlan, plan)) return;
    _activePlan = plan;
    await _transport.replace(plan.transportFactory());
  }

  bool _wantsPlan(DesktopCoreLaunchPlan plan) =>
      _wantsRunning && identical(_desired.plan, plan);

  Future<_LifecycleAchievement> _startForIntent(_LifecycleIntent intent) async {
    if (await _startSession(intent)) {
      _committedPlan = intent.plan;
      _recoveryPlan = null;
      return _LifecycleAchievement.runningFresh;
    }
    return _abandonedStart();
  }

  _LifecycleAchievement _abandonedStart() {
    if (_desired.target == _LifecycleTarget.stopped) {
      _publish(const DesktopCoreIdle());
    }
    return _LifecycleAchievement.idle;
  }

  Future<bool> _startSession(_LifecycleIntent intent) async {
    final revision = intent.revision;
    final sessionId = sessionIdFactory();
    _publish(DesktopCoreStarting(revision: revision, sessionId: sessionId));
    CoreProcessLease? lease;
    var leaseReleased = false;
    _TransportConnectionWaiter? connectionWaiter;

    Future<void> releaseLease() async {
      final ownedLease = lease;
      if (ownedLease == null || leaseReleased) {
        return;
      }
      leaseReleased = true;
      await _cleanObsoleteLease(ownedLease, revision);
    }

    try {
      if (!await _ensureTransportReady(intent.plan) ||
          !_wantsPlan(intent.plan)) {
        return false;
      }
      final launcher = await _activePlan.launcherResolver.resolve();
      if (!_wantsPlan(intent.plan)) {
        return false;
      }
      connectionWaiter = _TransportConnectionWaiter(
        _transport.events,
        timeouts.connection,
      );
      lease = await launcher.start(
        sessionId: sessionId,
        address: _transport.address,
      );
      if (lease.sessionId != sessionId) {
        await releaseLease();
        throw _failure(
          code: 'session_mismatch',
          phase: DesktopCorePhase.starting,
          revision: revision,
          lease: lease,
        );
      }
      if (!_wantsPlan(intent.plan)) {
        await releaseLease();
        return false;
      }
      _transport.observeProcess(lease);
      final connected = await _waitForConnectionWhileWanted(
        connectionWaiter.future,
        intent.plan,
      );
      if (connected == null || !_wantsPlan(intent.plan)) {
        await releaseLease();
        return false;
      }
      if (verifyPeerPid && connected.pid != lease.pid) {
        await releaseLease();
        throw _failure(
          code: 'peer_pid_mismatch',
          phase: DesktopCorePhase.starting,
          revision: revision,
          lease: lease,
          connectionGeneration: connected.generation,
          cause: StateError(
            'Expected Core PID ${lease.pid}, connected ${connected.pid}',
          ),
        );
      }
      final session = DesktopCoreSession(
        sessionId: sessionId,
        lease: lease,
        connectionGeneration: connected.generation,
      );
      _session = session;
      _sessionDisconnect = _SessionDisconnect(session);
      leaseReleased = true;
      _publish(DesktopCoreRunning(session));
      return true;
    } catch (error, stackTrace) {
      try {
        await releaseLease();
      } on DesktopCoreFailure catch (cleanupFailure) {
        Error.throwWithStackTrace(
          cleanupFailure,
          cleanupFailure.stackTrace ?? stackTrace,
        );
      }
      if (error is DesktopCoreFailure) {
        Error.throwWithStackTrace(error, error.stackTrace ?? stackTrace);
      }
      throw _failure(
        code: 'start_failed',
        phase: DesktopCorePhase.starting,
        revision: revision,
        cause: error,
        stackTrace: stackTrace,
      );
    } finally {
      await connectionWaiter?.cancel();
    }
  }

  Future<bool> _ensureTransportReady(DesktopCoreLaunchPlan plan) async {
    if (_transport.state == DesktopTransportState.failed ||
        _transport.state == DesktopTransportState.closed ||
        (_transport.state == DesktopTransportState.connected &&
            _session == null)) {
      await _transport.replace(_activePlan.transportFactory());
    }
    if (_transport.state == DesktopTransportState.ready ||
        _transport.state == DesktopTransportState.connected) {
      return true;
    }
    final opening = _transport.open().timeout(timeouts.ready);
    while (_wantsPlan(plan)) {
      final changed = _intentChanged.future;
      final result = await Future.any<Object?>([
        opening.then<Object?>((_) => true),
        changed.then<Object?>((_) => false),
      ]);
      if (result == true) {
        return true;
      }
    }
    return false;
  }

  Future<TransportConnected?> _waitForConnectionWhileWanted(
    Future<TransportConnected> connection,
    DesktopCoreLaunchPlan plan,
  ) async {
    while (_wantsPlan(plan)) {
      final changed = _intentChanged.future;
      final result = await Future.any<Object?>([
        connection,
        changed.then<Object?>((_) => null),
      ]);
      if (result is TransportConnected) {
        return result;
      }
    }
    return null;
  }

  Future<void> _cleanObsoleteLease(CoreProcessLease lease, int revision) async {
    late final CoreProcessStopResult result;
    try {
      result = await lease.stop(timeouts.disconnection);
    } catch (error, stackTrace) {
      _unconfirmedLease = lease;
      throw _failure(
        code: 'process_cleanup_failed',
        phase: DesktopCorePhase.stopping,
        revision: revision,
        lease: lease,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    if (result.exitConfirmed) {
      if (identical(_unconfirmedLease, lease)) {
        _unconfirmedLease = null;
      }
      return;
    }
    _unconfirmedLease = lease;
    throw _failure(
      code: 'process_exit_unconfirmed',
      phase: DesktopCorePhase.stopping,
      revision: revision,
      lease: lease,
    );
  }

  Future<void> _stopUnconfirmedLease(
    CoreProcessLease lease, {
    required bool allowFailure,
  }) async {
    try {
      final result = await lease.stop(timeouts.disconnection);
      if (result.exitConfirmed) {
        _unconfirmedLease = null;
      } else if (!allowFailure) {
        throw _failure(
          code: 'process_exit_unconfirmed',
          phase: DesktopCorePhase.stopping,
          revision: _desired.revision,
          lease: lease,
        );
      }
    } catch (_) {
      if (!allowFailure) {
        rethrow;
      }
    } finally {
      if (allowFailure) {
        _unconfirmedLease = null;
      }
    }
  }

  Future<void> _stopSession(
    DesktopCoreSession session,
    int revision, {
    required bool allowUnconfirmedExit,
  }) async {
    _publish(DesktopCoreStopping(revision: revision, session: session));
    final disconnected = _disconnectFor(session);
    try {
      final stopResult = await session.lease.stop(timeouts.disconnection);
      if (!stopResult.exitConfirmed) {
        if (!allowUnconfirmedExit) {
          throw _failure(
            code: 'process_exit_unconfirmed',
            phase: DesktopCorePhase.stopping,
            revision: revision,
            session: session,
          );
        }
        _clearSession(session);
        return;
      }
      if (!disconnected.isCompleted) {
        await Future.any<void>([
          disconnected.future,
          Future<void>.delayed(Duration.zero),
        ]);
      }
      if (!disconnected.isCompleted) {
        _clearSession(session);
        if (!_terminalRequested) {
          await _transport.replace(_activePlan.transportFactory());
        }
        return;
      }
      _clearSession(session);
    } on DesktopCoreFailure {
      rethrow;
    } catch (error, stackTrace) {
      if (allowUnconfirmedExit) {
        _clearSession(session);
        return;
      }
      throw _failure(
        code: 'stop_failed',
        phase: DesktopCorePhase.stopping,
        revision: revision,
        session: session,
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  _SessionDisconnect _disconnectFor(DesktopCoreSession session) {
    final current = _sessionDisconnect;
    if (current != null && identical(current.session, session)) {
      return current;
    }
    return _sessionDisconnect = _SessionDisconnect(session);
  }

  void _clearSession(DesktopCoreSession session) {
    if (identical(_session, session)) {
      _session = null;
    }
    if (identical(_sessionDisconnect?.session, session)) {
      _sessionDisconnect = null;
    }
  }

  bool _satisfies(_LifecycleAchievement achievement, _LifecycleTarget target) {
    return switch (target) {
      _LifecycleTarget.running =>
        achievement == _LifecycleAchievement.runningExisting ||
            achievement == _LifecycleAchievement.runningFresh,
      _LifecycleTarget.restarted =>
        achievement == _LifecycleAchievement.runningFresh,
      _LifecycleTarget.stopped => achievement == _LifecycleAchievement.idle,
      _LifecycleTarget.closed => achievement == _LifecycleAchievement.closed,
    };
  }

  void _completeCommands(_LifecycleIntent settled) {
    final commands = _pending
        .where((command) => command.intent.revision <= settled.revision)
        .toList(growable: false);
    _pending.removeWhere(
      (command) => command.intent.revision <= settled.revision,
    );
    for (final command in commands) {
      final outcome = command.intent.revision == settled.revision
          ? CoreLifecycleOutcome.applied
          : identical(command.intent.plan, settled.plan) &&
                _targetsCoalesce(command.intent.target, settled.target)
          ? CoreLifecycleOutcome.coalesced
          : CoreLifecycleOutcome.superseded;
      command.completer.complete(
        CoreLifecycleResult(
          revision: command.intent.revision,
          outcome: outcome,
          session: _session,
        ),
      );
    }
  }

  bool _targetsCoalesce(_LifecycleTarget first, _LifecycleTarget settled) {
    final firstRuns =
        first == _LifecycleTarget.running ||
        first == _LifecycleTarget.restarted;
    final settledRuns =
        settled == _LifecycleTarget.running ||
        settled == _LifecycleTarget.restarted;
    return (firstRuns && settledRuns) || first == settled;
  }

  void _failCommands(
    int revision,
    DesktopCoreFailure failure, {
    DesktopCoreLaunchPlan? rejectedPlan,
  }) {
    final commands = _pending
        .where((command) => command.intent.revision <= revision)
        .toList(growable: false);
    _pending.removeWhere((command) => command.intent.revision <= revision);
    for (final command in commands) {
      if (rejectedPlan != null &&
          !identical(command.intent.plan, rejectedPlan)) {
        command.completer.complete(
          CoreLifecycleResult(
            revision: command.intent.revision,
            outcome: CoreLifecycleOutcome.superseded,
            session: _session,
          ),
        );
      } else {
        command.completer.completeError(failure, failure.stackTrace);
      }
    }
  }

  void _handleTransportEvent(DesktopTransportEvent event) {
    if (event case TransportDisconnected(:final generation)) {
      _sessionDisconnect?.record(generation);
    }
    final running = _state;
    if (running is! DesktopCoreRunning) {
      return;
    }
    switch (event) {
      case TransportDisconnected(:final generation, :final error)
          when generation == running.session.connectionGeneration:
        _handleUnexpectedDisconnect(
          running.session,
          code: 'unexpected_disconnect',
          cause: error,
        );
      case TransportFailed(:final error, :final stackTrace):
        _handleUnexpectedDisconnect(
          running.session,
          code: 'transport_failed',
          cause: error,
          stackTrace: stackTrace,
        );
      case TransportReady() || TransportConnected() || TransportDisconnected():
        break;
    }
  }

  void _handleUnexpectedDisconnect(
    DesktopCoreSession session, {
    required String code,
    Object? cause,
    StackTrace? stackTrace,
  }) {
    if (_unexpectedDisconnectOperation != null ||
        !identical(_session, session)) {
      return;
    }
    _clearSession(session);
    final failure = _failure(
      code: code,
      phase: DesktopCorePhase.running,
      revision: _revision,
      session: session,
      cause: cause,
      stackTrace: stackTrace,
    );
    _publish(DesktopCoreFailed(failure));
    if (!_crashController.isClosed) {
      _crashController.add(failure);
    }
    late final Future<void> operation;
    operation = session.lease
        .stop(timeouts.disconnection)
        .then<void>((result) {
          if (!result.exitConfirmed) {
            _unconfirmedLease = session.lease;
          }
        })
        .catchError((_) {
          _unconfirmedLease = session.lease;
        })
        .whenComplete(() {
          if (identical(_unexpectedDisconnectOperation, operation)) {
            _unexpectedDisconnectOperation = null;
          }
        });
    _unexpectedDisconnectOperation = operation;
  }

  DesktopCoreFailure _failure({
    required String code,
    required DesktopCorePhase phase,
    required int revision,
    DesktopCoreSession? session,
    CoreProcessLease? lease,
    int? connectionGeneration,
    Object? cause,
    StackTrace? stackTrace,
  }) {
    return DesktopCoreFailure(
      code: code,
      phase: phase,
      revision: revision,
      sessionId: session?.sessionId ?? lease?.sessionId,
      owner: session?.owner ?? lease?.owner,
      pid: session?.pid ?? lease?.pid,
      connectionGeneration:
          connectionGeneration ?? session?.connectionGeneration,
      cause: cause,
      stackTrace: stackTrace,
    );
  }

  void _publish(DesktopCoreState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  @override
  Future<DesktopCoreSession> waitUntilRunning(Duration timeout) {
    final current = _state;
    if (current is DesktopCoreRunning) {
      return Future.value(current.session);
    }
    if (current is DesktopCoreFailed) {
      return Future.error(current.failure, current.failure.stackTrace);
    }
    if (current is DesktopCoreClosed) {
      return Future.error(StateError('Desktop Core lifecycle is closed'));
    }
    return states
        .firstWhere(
          (state) =>
              state is DesktopCoreRunning ||
              state is DesktopCoreFailed ||
              state is DesktopCoreClosed,
        )
        .then<DesktopCoreSession>((state) {
          if (state case DesktopCoreRunning(:final session)) {
            return session;
          }
          if (state case DesktopCoreFailed(:final failure)) {
            Error.throwWithStackTrace(
              failure,
              failure.stackTrace ?? StackTrace.current,
            );
          }
          throw StateError('Desktop Core lifecycle is closed');
        })
        .timeout(timeout);
  }
}

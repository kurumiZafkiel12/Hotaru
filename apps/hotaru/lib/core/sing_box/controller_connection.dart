import 'dart:async';
import 'dart:io';

import '../desktop/connection.dart';
import '../desktop/listener_owner.dart';
import '../desktop/model.dart';
import 'clash_api_adapter.dart';

final class SingBoxControllerConnection
    implements DesktopCoreConnection, DesktopCoreProcessObserver {
  final SingBoxClashApiAdapter _api;
  final Future<int?> Function() _peerPid;
  final bool verifyPeerPid;
  final Duration interval;
  final StreamController<DesktopTransportEvent> _events =
      StreamController<DesktopTransportEvent>.broadcast();
  DesktopTransportState _state = DesktopTransportState.idle;
  CoreProcessExitSource? _process;
  Timer? _timer;
  Future<void>? _polling;
  Future<void>? _closing;
  TransportConnected? _connection;
  TransportFailed? _failure;
  int _generation = 0;
  int _failures = 0;
  bool _hostReady = false;

  @override
  final String address;

  SingBoxControllerConnection({
    required Uri endpoint,
    required String secret,
    bool? verifyPeerPid,
    Future<int?> Function()? peerPid,
    this.interval = const Duration(milliseconds: 250),
  }) : address = endpoint.toString(),
       _api = SingBoxClashApiAdapter(endpoint: endpoint, secret: secret),
       verifyPeerPid = verifyPeerPid ?? Platform.isWindows,
       _peerPid = peerPid ?? (() => windowsListenerOwner(endpoint));

  @override
  DesktopTransportState get state => _state;

  @override
  Stream<DesktopTransportEvent> get events => _events.stream;

  bool get _terminal =>
      _state == DesktopTransportState.closed ||
      _state == DesktopTransportState.failed;

  @override
  Future<void> open() async {
    if (_terminal) throw StateError('Controller connection is terminal');
    if (_state != DesktopTransportState.idle) return;
    _state = DesktopTransportState.ready;
    _events.add(const TransportReady());
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  @override
  void observeProcess(CoreProcessExitSource process) {
    if (_terminal) return;
    if (_process != null && !identical(_process, process)) {
      _fail(StateError('Controller process changed without a new connection'));
      return;
    }
    _process = process;
    unawaited(
      process.exitCode.then<void>(
        (code) {
          if (!_terminal && identical(_process, process)) {
            _fail(StateError('Owned core exited: $code'));
          }
        },
        onError: (Object error, StackTrace trace) {
          if (!_terminal) _fail(error, trace);
        },
      ),
    );
    if (process is CoreProcessReadySource) {
      unawaited(
        process.ready.then<void>(
          (_) {
            if (_terminal) return;
            _hostReady = true;
            _tick();
          },
          onError: (Object error, StackTrace trace) {
            if (!_terminal) _fail(error, trace);
          },
        ),
      );
    } else {
      _hostReady = true;
      _tick();
    }
  }

  void _tick() {
    if (_terminal || _process == null || !_hostReady || _polling != null) {
      return;
    }
    _polling = _poll().whenComplete(() => _polling = null);
  }

  Future<void> _poll() async {
    try {
      final version = await _api.version();
      if (_terminal) return;
      if (version != 'sing-box 1.14.4') {
        _fail(StateError('Unexpected controller version'));
        return;
      }
      _failures = 0;
      if (_connection != null) return;
      final pid = verifyPeerPid ? await _peerPid() : null;
      if (_terminal) return;
      if (verifyPeerPid && pid == null) return;
      if (verifyPeerPid && pid != _process!.pid) {
        _fail(StateError('Controller listener PID does not match owned core'));
        return;
      }
      final connected = TransportConnected(pid: pid, generation: ++_generation);
      _connection = connected;
      _state = DesktopTransportState.connected;
      _events.add(connected);
    } catch (error, trace) {
      if (_terminal) return;
      if (_connection != null && ++_failures >= 3) _fail(error, trace);
    }
  }

  void _fail(Object error, [StackTrace? trace]) {
    if (_terminal) return;
    final failure = TransportFailed(error, trace ?? StackTrace.current);
    _failure = failure;
    _state = DesktopTransportState.failed;
    _timer?.cancel();
    _connection = null;
    _events.add(failure);
  }

  @override
  Future<TransportConnected> waitUntilConnected(Duration timeout) {
    final connected = _connection;
    if (connected != null) return Future.value(connected);
    final failure = _failure;
    if (failure != null) return Future.error(failure.error, failure.stackTrace);
    if (_state == DesktopTransportState.closed) {
      return Future.error(StateError('Controller connection is closed'));
    }
    return events
        .firstWhere(
          (event) => event is TransportConnected || event is TransportFailed,
        )
        .then((event) {
          if (event is TransportConnected) return event;
          final failed = event as TransportFailed;
          Error.throwWithStackTrace(failed.error, failed.stackTrace);
        })
        .timeout(timeout);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _state = DesktopTransportState.closed;
    _timer?.cancel();
    _connection = null;
    await _api.close();
    await _polling;
    await _events.close();
  }
}

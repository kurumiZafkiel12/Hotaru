import 'dart:async';
import 'dart:convert';

import '../desktop/model.dart';
import '../desktop/transport.dart';
import 'host_events.dart';
import 'bootstrap.dart';

final class SingBoxPipeConnection
    implements DesktopCoreConnection, DesktopCoreProcessObserver {
  final DesktopCoreTransport _pipe;
  final DesktopCoreConnection _controller;
  final SingBoxBootstrap _bootstrapConfig;
  final StreamController<DesktopTransportEvent> _events =
      StreamController<DesktopTransportEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  DesktopTransportState _state = DesktopTransportState.idle;
  CoreProcessLease? _process;
  TransportConnected? _peer;
  TransportConnected? _connected;
  TransportFailed? _failure;
  SingBoxHostEvents? _host;
  Future<void>? _bootstrapping;
  Future<void>? _closing;
  bool _sentConfig = false;
  bool _stopping = false;

  SingBoxPipeConnection({
    required DesktopCoreTransport pipe,
    required DesktopCoreConnection controller,
    required SingBoxBootstrap bootstrap,
  }) : _pipe = pipe,
       _controller = controller,
       _bootstrapConfig = bootstrap;

  @override
  String get address => _pipe.address;
  @override
  DesktopTransportState get state => _state;
  @override
  Stream<DesktopTransportEvent> get events => _events.stream;

  bool get _terminal =>
      _state == DesktopTransportState.closed ||
      _state == DesktopTransportState.failed;

  @override
  Future<void> open() async {
    if (_terminal) throw StateError('Host pipe is terminal');
    if (_state != DesktopTransportState.idle) return;
    _state = DesktopTransportState.starting;
    _subscriptions.addAll([
      _pipe.events.listen(_pipeEvent, onError: _fail),
      _pipe.frames.listen((frame) {
        final host = _host;
        if (host == null || !_sentConfig) {
          _fail(StateError('Host output preceded verified bootstrap'));
          return;
        }
        try {
          host.add(utf8.decode(frame));
          if (host.failed) _fail(StateError('Invalid host control event'));
        } on FormatException {
          host.fail();
          _fail(StateError('Invalid host frame'));
        }
      }, onError: _fail),
      _controller.events.listen((event) {
        if (_terminal) return;
        switch (event) {
          case TransportConnected():
            final peer = _peer;
            if (peer == null || event.pid != peer.pid) {
              _fail(StateError('Controller and pipe PID differ'));
              return;
            }
            _connected = peer;
            _state = DesktopTransportState.connected;
            _events.add(peer);
          case TransportFailed():
            _fail(event.error, event.stackTrace);
          case TransportDisconnected():
            _fail(StateError('Controller disconnected'));
          case TransportReady():
            break;
        }
      }, onError: _fail),
    ]);
    try {
      await _pipe.open();
      await _controller.open();
      if (_terminal) return;
      _state = DesktopTransportState.ready;
      _events.add(const TransportReady());
    } catch (error, trace) {
      _fail(error, trace);
      rethrow;
    }
  }

  void _pipeEvent(DesktopTransportEvent event) {
    if (event is TransportDisconnected || event is TransportFailed) {
      _host?.finish();
    }
    if (_terminal) return;
    switch (event) {
      case TransportConnected():
        if (_peer != null) {
          _fail(StateError('Host pipe reconnected within a session'));
          return;
        }
        _peer = event;
        _tryBootstrap();
      case TransportDisconnected():
        _fail(StateError('Host pipe disconnected'));
      case TransportFailed():
        _fail(event.error, event.stackTrace);
      case TransportReady():
        break;
    }
  }

  @override
  void observeProcess(CoreProcessLease process) {
    if (_terminal) return;
    if (_process != null && !identical(_process, process)) {
      _fail(StateError('Host process changed within a session'));
      return;
    }
    _process = process;
    _tryBootstrap();
  }

  void _tryBootstrap() {
    final process = _process;
    final peer = _peer;
    if (_terminal ||
        _stopping ||
        _bootstrapping != null ||
        process == null ||
        peer == null) {
      return;
    }
    if (peer.pid != process.pid) {
      _fail(StateError('Host pipe PID does not match the owned lease'));
      return;
    }
    _host = SingBoxHostEvents(process.pid);
    _bootstrapping = _bootstrap(process).catchError((
      Object error,
      StackTrace trace,
    ) {
      _fail(error, trace);
    });
  }

  Future<void> _bootstrap(CoreProcessLease process) async {
    final payload = _bootstrapConfig.bytes;
    if (_terminal || _stopping) return;
    _sentConfig = true;
    _pipe.send(payload);
    await _host!.ready;
    if (_terminal || _stopping) return;
    final controller = _controller;
    if (controller case final DesktopCoreProcessObserver observer) {
      observer.observeProcess(process);
    } else {
      throw StateError('Controller must verify process ownership');
    }
  }

  Future<bool> gracefulStop(Duration timeout) async {
    _stopping = true;
    if (!_sentConfig) {
      await _pipe.close();
      _host?.finish();
      return true;
    }
    final host = _host!;
    try {
      _pipe.send(utf8.encode('stop\n'));
    } catch (_) {
      // A broken pipe does not establish engine cleanup.
    }
    try {
      await host.finished.timeout(timeout);
    } on TimeoutException {
      return false;
    }
    return host.clean;
  }

  void _fail(Object error, [StackTrace? trace]) {
    if (_terminal) return;
    final failure = TransportFailed(error, trace ?? StackTrace.current);
    _failure = failure;
    _state = DesktopTransportState.failed;
    _events.add(failure);
  }

  @override
  Future<TransportConnected> waitUntilConnected(Duration timeout) {
    final connected = _connected;
    if (connected != null && !_terminal) return Future.value(connected);
    final failure = _failure;
    if (failure != null) return Future.error(failure.error, failure.stackTrace);
    if (_terminal) return Future.error(StateError('Host pipe is closed'));
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
    _stopping = true;
    try {
      await _pipe.close();
    } finally {
      _host?.finish();
      await _bootstrapping;
      try {
        await _controller.close();
      } finally {
        for (final subscription in _subscriptions) {
          await subscription.cancel();
        }
        await _events.close();
      }
    }
  }
}

final class SingBoxPipeLease implements CoreProcessLease {
  final CoreProcessLease process;
  final SingBoxPipeConnection connection;
  Future<CoreProcessStopResult>? _stopping;

  SingBoxPipeLease({required this.process, required this.connection});

  @override
  String get sessionId => process.sessionId;
  @override
  int get pid => process.pid;
  @override
  CoreProcessOwner get owner => process.owner;

  @override
  Future<CoreProcessStopResult> stop(Duration timeout) {
    return _stopping ??= _stop(timeout)
        .then((result) {
          if (!result.exitConfirmed) _stopping = null;
          return result;
        })
        .onError((Object error, StackTrace trace) {
          _stopping = null;
          Error.throwWithStackTrace(error, trace);
        });
  }

  Future<CoreProcessStopResult> _stop(Duration timeout) async {
    final elapsed = Stopwatch()..start();
    if (!await connection.gracefulStop(timeout)) {
      return const CoreProcessStopResult(stopped: false, exitConfirmed: false);
    }
    final remaining = timeout - elapsed.elapsed;
    return process.stop(remaining.isNegative ? Duration.zero : remaining);
  }
}

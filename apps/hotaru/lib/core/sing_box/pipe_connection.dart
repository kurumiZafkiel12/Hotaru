import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../desktop/model.dart';
import '../adapter.dart';
import '../telemetry.dart';
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
  Future<void> _frames = Future.value();
  Future<void>? _outputEnd;
  final Map<int, Completer<CoreTelemetrySnapshot>> _pendingTelemetry = {};
  int _requestId = 0;
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
        _frames = _frames.then((_) => _handleFrame(frame)).catchError((
          Object error,
          StackTrace trace,
        ) {
          _host?.fail();
          _fail(error, trace);
        });
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

  Future<void> _handleFrame(Uint8List frame) async {
    if (_state == DesktopTransportState.closed) return;
    final host = _host;
    if (host == null || !_sentConfig) {
      _fail(StateError('Host output preceded verified bootstrap'));
      return;
    }
    final decoded = await Isolate.run(() => _decodeControlFrame(frame));
    if (_state == DesktopTransportState.closed) return;
    final value = decoded.value;
    if (value is Map<String, dynamic> && value['event'] == 'telemetry') {
      if (!host.acceptsTelemetry) {
        host.fail();
        _fail(StateError('Telemetry outside the ready host lifetime'));
        return;
      }
      if (_terminal) return;
      final id = value['request_id'];
      if (value['protocol'] != 'hotaru-stdio-v1' ||
          value['pid'] != _process?.pid ||
          id is! int ||
          id < 1 ||
          id > _requestId) {
        _fail(StateError('Invalid host telemetry identity'));
        return;
      }
      final pending = _pendingTelemetry.remove(id);
      if (pending == null) return;
      final data = decoded.snapshot;
      if (value['error'] case final String error) {
        pending.completeError(
          CoreAdapterException(
            error == 'telemetry_too_large' ? error : 'telemetry_unavailable',
          ),
        );
      } else if (data != null) {
        pending.complete(data);
      } else {
        pending.completeError(const CoreAdapterException('invalid_response'));
      }
      return;
    }
    host.addValue(value);
    if (host.failed) _fail(StateError('Invalid host control event'));
  }

  Future<CoreTelemetrySnapshot> telemetry() async {
    if (_terminal || _stopping || _state != DesktopTransportState.connected) {
      throw const CoreAdapterException('core_not_running');
    }
    if (_pendingTelemetry.length >= 8 || _requestId >= 0xffffffff) {
      throw const CoreAdapterException('busy');
    }
    final id = ++_requestId;
    final pending = Completer<CoreTelemetrySnapshot>();
    _pendingTelemetry[id] = pending;
    final result = pending.future
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            throw const CoreAdapterException('timeout');
          },
        )
        .whenComplete(() => _pendingTelemetry.remove(id));
    try {
      _pipe.send(
        utf8.encode('${jsonEncode({'method': 'telemetry', 'id': id})}\n'),
      );
    } catch (error, trace) {
      _pendingTelemetry.remove(id);
      pending.completeError(error, trace);
    }
    return result;
  }

  void _cancelTelemetry() {
    for (final pending in _pendingTelemetry.values) {
      pending.completeError(const CoreAdapterException('session_changed'));
    }
    _pendingTelemetry.clear();
  }

  void _pipeEvent(DesktopTransportEvent event) {
    if (event is TransportDisconnected || event is TransportFailed) {
      _outputEnd ??= _finishOutput();
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

  Future<void> _finishOutput() async {
    // Frames and lifecycle events use separate broadcast streams. Drain their
    // queued deliveries before committing EOF behind the decode queue.
    await Future<void>.delayed(Duration.zero);
    await _frames;
    _host?.finish();
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

  Future<CoreTrafficTotals?> get finalTraffic async {
    final host = _host;
    if (host == null) return null;
    await host.finished;
    return host.totals;
  }

  Future<bool> gracefulStop(Duration timeout) async {
    _stopping = true;
    _cancelTelemetry();
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
    _cancelTelemetry();
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
    _cancelTelemetry();
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
        await _frames;
        await _outputEnd;
        await _events.close();
      }
    }
  }
}

final class SingBoxPipeLease
    implements CoreProcessLease, CoreFinalTrafficSource {
  final CoreProcessLease process;
  final SingBoxPipeConnection connection;
  @override
  final int? profileId;
  Future<CoreProcessStopResult>? _stopping;

  SingBoxPipeLease({
    required this.process,
    required this.connection,
    this.profileId,
  });

  @override
  Future<CoreTrafficTotals?> get finalTraffic => connection.finalTraffic;

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

({Object? value, CoreTelemetrySnapshot? snapshot}) _decodeControlFrame(
  Uint8List frame,
) {
  final value = jsonDecode(utf8.decode(frame));
  CoreTelemetrySnapshot? snapshot;
  if (value is Map<String, dynamic> && value['event'] == 'telemetry') {
    final data = value.remove('data');
    if (data != null) {
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Invalid telemetry payload');
      }
      snapshot = CoreTelemetrySnapshot.fromJson(data);
    }
  }
  return (value: value, snapshot: snapshot);
}

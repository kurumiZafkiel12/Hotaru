import 'dart:async';
import 'dart:typed_data';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:rust_api/rust_api.dart';

import 'connection.dart';

export 'connection.dart';

typedef IpcServerBinder = Future<IpcServer> Function(String address);

abstract interface class DesktopCoreTransport implements DesktopCoreConnection {
  Stream<Uint8List> get frames;
  void send(List<int> frame);
}

final class DesktopCoreTransportBinding extends DesktopCoreConnectionBinding
    implements DesktopCoreTransport {
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _frameSubscription;
  Future<void>? _closingFrames;

  DesktopCoreTransportBinding(DesktopCoreTransport transport)
    : super(transport) {
    _bindFrames(transport);
  }

  void _bindFrames(DesktopCoreTransport transport) {
    _frameSubscription = transport.frames.listen(
      _frames.add,
      onError: _frames.addError,
    );
  }

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> replace(covariant DesktopCoreTransport next) async {
    if (_closingFrames != null) {
      throw StateError('IPC transport binding is closed');
    }
    await _frameSubscription?.cancel();
    try {
      await super.replace(next);
    } finally {
      if (identical(current, next)) {
        _bindFrames(next);
      }
    }
  }

  @override
  void send(List<int> frame) => (current as DesktopCoreTransport).send(frame);

  @override
  Future<void> close() => _closingFrames ??= _closeFrames();

  Future<void> _closeFrames() async {
    await _frameSubscription?.cancel();
    try {
      await super.close();
    } finally {
      await _frames.close();
    }
  }
}

final class IpcCoreTransport implements DesktopCoreTransport {
  @override
  final String address;

  final IpcServerBinder _bind;
  final StreamController<DesktopTransportEvent> _eventController =
      StreamController<DesktopTransportEvent>.broadcast();
  final StreamController<Uint8List> _frameController =
      StreamController<Uint8List>.broadcast();

  IpcServer? _server;
  StreamSubscription<IpcEvent>? _subscription;
  Future<void>? _openOperation;
  Future<void>? _closeOperation;
  DesktopTransportState _state = DesktopTransportState.idle;
  TransportConnected? _connection;
  TransportFailed? _failure;
  int _connectionGeneration = 0;

  IpcCoreTransport({required this.address, IpcServerBinder? bind})
    : _bind = bind ?? _bindIpcServer;

  static Future<IpcServer> _bindIpcServer(String address) {
    return IpcServer.bind(address: address);
  }

  @override
  DesktopTransportState get state => _state;

  @override
  Stream<DesktopTransportEvent> get events => _eventController.stream;

  @override
  Stream<Uint8List> get frames => _frameController.stream;

  @override
  Future<void> open() {
    if (_state == DesktopTransportState.closed) {
      return Future.error(StateError('IPC transport is closed'));
    }
    final failure = _failure;
    if (failure != null) {
      return Future.error(failure.error, failure.stackTrace);
    }
    return _openOperation ??= _open();
  }

  Future<void> _open() async {
    _state = DesktopTransportState.starting;
    try {
      final server = await _bind(address);
      if (_state == DesktopTransportState.closed) {
        await server.close();
        throw StateError('IPC transport is closed');
      }
      _server = server;
      _state = DesktopTransportState.ready;
      commonPrint.log('IPC Ready');
      _eventController.add(const TransportReady());
      _subscription = server.events().listen(
        _handleEvent,
        onError: _fail,
        onDone: _handleDone,
      );
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
      rethrow;
    }
  }

  bool get _isTerminal =>
      _state == DesktopTransportState.failed ||
      _state == DesktopTransportState.closed;

  void _handleEvent(IpcEvent event) {
    if (_isTerminal) {
      return;
    }
    switch (event.kind) {
      case IpcEventKind.connected:
        _connect(event.pid);
      case IpcEventKind.message:
        _frameController.add(event.payload);
      case IpcEventKind.disconnected:
        _disconnect(event.error);
      case IpcEventKind.failed:
        _fail(StateError('IPC error: ${event.error}'), StackTrace.current);
    }
  }

  void _connect(int? pid) {
    commonPrint.log('IPC Connected${pid == null ? '' : ': $pid'}');
    final connection = TransportConnected(
      pid: pid,
      generation: ++_connectionGeneration,
    );
    _connection = connection;
    _state = DesktopTransportState.connected;
    _eventController.add(connection);
  }

  void _disconnect(String? error) {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    commonPrint.log(
      'IPC Disconnected${error == null ? '' : ': $error'}',
      logLevel: error == null ? LogLevel.info : LogLevel.warning,
    );
    _connection = null;
    _state = DesktopTransportState.ready;
    _eventController.add(
      TransportDisconnected(
        connection.generation,
        error: error == null ? null : StateError('IPC error: $error'),
      ),
    );
  }

  void _handleDone() {
    _fail(StateError('IPC server stopped unexpectedly'), StackTrace.current);
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_isTerminal) {
      return;
    }
    commonPrint.log('IPC error: $error', logLevel: LogLevel.debug);
    final failure = TransportFailed(error, stackTrace);
    _connection = null;
    _failure = failure;
    _state = DesktopTransportState.failed;
    _eventController.add(failure);
  }

  @override
  Future<TransportConnected> waitUntilConnected(Duration timeout) {
    final connection = _connection;
    if (connection != null) {
      return Future.value(connection);
    }
    final failure = _failure;
    if (failure != null) {
      return Future.error(failure.error, failure.stackTrace);
    }
    return events
        .firstWhere(
          (event) => event is TransportConnected || event is TransportFailed,
        )
        .then<TransportConnected>((event) {
          if (event case TransportConnected()) {
            return event;
          }
          final failure = event as TransportFailed;
          Error.throwWithStackTrace(failure.error, failure.stackTrace);
        })
        .timeout(timeout);
  }

  @override
  void send(List<int> frame) {
    if (_state == DesktopTransportState.closed) {
      throw StateError('IPC transport is closed');
    }
    final server = _server;
    if (server == null) {
      throw StateError('IPC transport is not open');
    }
    server.send(message: frame);
  }

  @override
  Future<void> close() {
    return _closeOperation ??= _close();
  }

  Future<void> _close() async {
    _state = DesktopTransportState.closed;
    _connection = null;
    try {
      await _server?.close();
    } finally {
      await _subscription?.cancel();
      await _eventController.close();
      await _frameController.close();
    }
  }
}

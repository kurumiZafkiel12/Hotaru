import 'dart:async';

import 'model.dart';

abstract interface class DesktopCoreProcessObserver {
  void observeProcess(CoreProcessLease process);
}

enum DesktopTransportState { idle, starting, ready, connected, failed, closed }

sealed class DesktopTransportEvent {
  const DesktopTransportEvent();
}

final class TransportReady extends DesktopTransportEvent {
  const TransportReady();
}

final class TransportConnected extends DesktopTransportEvent {
  final int? pid;
  final int generation;

  const TransportConnected({required this.pid, required this.generation});
}

final class TransportDisconnected extends DesktopTransportEvent {
  final int generation;
  final Object? error;

  const TransportDisconnected(this.generation, {this.error});
}

final class TransportFailed extends DesktopTransportEvent {
  final Object error;
  final StackTrace stackTrace;

  const TransportFailed(this.error, this.stackTrace);
}

abstract interface class DesktopCoreConnection {
  String get address;
  DesktopTransportState get state;
  Stream<DesktopTransportEvent> get events;
  Future<void> open();
  Future<TransportConnected> waitUntilConnected(Duration timeout);
  Future<void> close();
}

class DesktopCoreConnectionBinding implements DesktopCoreConnection {
  DesktopCoreConnection _connection;
  final StreamController<DesktopTransportEvent> _events =
      StreamController<DesktopTransportEvent>.broadcast();
  StreamSubscription<DesktopTransportEvent>? _subscription;
  Future<void>? _closing;

  DesktopCoreConnectionBinding(DesktopCoreConnection connection)
    : _connection = connection {
    _bind(connection);
  }

  DesktopCoreConnection get current => _connection;

  void observeProcess(CoreProcessLease process) {
    if (_connection case final DesktopCoreProcessObserver observer) {
      observer.observeProcess(process);
    }
  }

  void _bind(DesktopCoreConnection connection) {
    _subscription = connection.events.listen(
      _events.add,
      onError: _events.addError,
    );
  }

  @override
  String get address => _connection.address;

  @override
  DesktopTransportState get state => _connection.state;

  @override
  Stream<DesktopTransportEvent> get events => _events.stream;

  Future<void> replace(DesktopCoreConnection next) async {
    if (_closing != null) throw StateError('Core connection binding is closed');
    final previous = _connection;
    if (previous.state == DesktopTransportState.connected) {
      _events.add(
        TransportFailed(
          StateError('Connected Core transport was replaced'),
          StackTrace.current,
        ),
      );
    }
    await _subscription?.cancel();
    try {
      await previous.close();
    } finally {
      _connection = next;
      _bind(next);
    }
  }

  @override
  Future<void> open() => _connection.open();

  @override
  Future<TransportConnected> waitUntilConnected(Duration timeout) =>
      _connection.waitUntilConnected(timeout);

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await _subscription?.cancel();
    try {
      await _connection.close();
    } finally {
      await _events.close();
    }
  }
}

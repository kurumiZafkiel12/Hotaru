import 'dart:async';
import 'dart:convert';

final class SingBoxHostEvents {
  final int pid;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _finished = Completer<void>();
  bool _clean = false;
  bool _failed = false;
  bool _stopped = false;

  SingBoxHostEvents(this.pid) {
    _ready.future.ignore();
  }

  Future<void> get ready => _ready.future;
  Future<void> get finished => _finished.future;
  bool get clean => _clean && !_failed;
  bool get failed => _failed;
  bool get acceptsTelemetry =>
      _ready.isCompleted && !_stopped && !_failed && !_finished.isCompleted;

  void fail() {
    _failed = true;
    _clean = false;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Invalid host control output'));
    }
  }

  void add(String line) {
    try {
      addValue(jsonDecode(line));
    } on FormatException {
      fail();
    }
  }

  void addValue(Object? value) {
    if (_finished.isCompleted ||
        _stopped ||
        value is! Map<String, dynamic> ||
        value['pid'] is! int ||
        value['protocol'] != 'hotaru-stdio-v1' ||
        value['pid'] != pid) {
      fail();
      return;
    }
    switch (value['event']) {
      case 'ready':
        if (_ready.isCompleted) {
          fail();
        } else {
          _ready.complete();
        }
      case 'stopped':
        _stopped = true;
        _clean = !_failed && value['clean'] == true;
        if (!_ready.isCompleted) {
          _ready.completeError(StateError('Host stopped before ready'));
        }
      default:
        fail();
    }
  }

  void finish() {
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Host exited before ready'));
    }
    if (!_finished.isCompleted) _finished.complete();
  }
}

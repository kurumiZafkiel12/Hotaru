import 'dart:async';
import 'dart:convert';

import '../telemetry.dart';

final class SingBoxHostEvents {
  final int pid;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _finished = Completer<void>();
  bool _clean = false;
  bool _failed = false;
  bool _stopped = false;
  CoreTrafficTotals? _totals;
  Set<String> _features = const {};

  SingBoxHostEvents(this.pid) {
    _ready.future.ignore();
  }

  Future<void> get ready => _ready.future;
  Future<void> get finished => _finished.future;
  bool get clean => _clean && !_failed;
  bool get failed => _failed;
  CoreTrafficTotals? get totals => clean ? _totals : null;
  bool get acceptsTelemetry =>
      _ready.isCompleted && !_stopped && !_failed && !_finished.isCompleted;

  bool supports(String feature) =>
      acceptsTelemetry && _features.contains(feature);

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
          final features = value['features'];
          if (features != null) {
            if (features is! List ||
                features.length > 16 ||
                features.any(
                  (item) =>
                      item is! String ||
                      !RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(item),
                ) ||
                features.toSet().length != features.length) {
              fail();
              return;
            }
            _features = Set<String>.unmodifiable(features.cast<String>());
          }
          _ready.complete();
        }
      case 'stopped':
        final totals = value['totals'];
        if (totals != null) {
          try {
            if (totals is! Map<String, dynamic>) throw const FormatException();
            _totals = CoreTrafficTotals.fromJson(totals);
          } on FormatException {
            fail();
          }
        }
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

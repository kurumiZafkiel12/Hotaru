import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../desktop/model.dart';

final class StdioCoreLease implements CoreProcessReadySource {
  final Process _process;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _outputDone = Completer<void>();
  bool _clean = false;
  bool _protocolFailed = false;
  bool _stopped = false;
  Future<CoreProcessStopResult>? _stopping;

  @override
  final String sessionId;

  StdioCoreLease({
    required this.sessionId,
    required Process process,
    void Function(String)? onStderr,
  }) : _process = process {
    _ready.future.ignore();
    process.stdin.done.ignore();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _event,
          onError: (Object error) => _invalidOutput(),
          onDone: () {
            if (!_ready.isCompleted) {
              _ready.completeError(StateError('Host exited before ready'));
            }
            if (!_outputDone.isCompleted) _outputDone.complete();
          },
          cancelOnError: false,
        );
    process.stderr
        .transform(utf8.decoder)
        .listen(onStderr ?? (_) {}, onError: (Object _) {});
  }

  void _invalidOutput() {
    _protocolFailed = true;
    _clean = false;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Invalid host control output'));
    }
  }

  void _event(String line) {
    try {
      final value = jsonDecode(line);
      if (_stopped ||
          value is! Map<String, dynamic> ||
          value['pid'] is! int ||
          value['protocol'] != 'hotaru-stdio-v1' ||
          value['pid'] != pid) {
        _invalidOutput();
        return;
      }
      switch (value['event']) {
        case 'ready':
          if (_ready.isCompleted) {
            _invalidOutput();
          } else {
            _ready.complete();
          }
        case 'stopped':
          _stopped = true;
          _clean = !_protocolFailed && value['clean'] == true;
          if (!_ready.isCompleted) {
            _ready.completeError(StateError('Host stopped before ready'));
          }
        default:
          _invalidOutput();
      }
    } on FormatException {
      _invalidOutput();
    }
  }

  @override
  CoreProcessOwner get owner => CoreProcessOwner.direct;
  @override
  int get pid => _process.pid;
  @override
  Future<int> get exitCode => _process.exitCode;
  @override
  Future<void> get ready => _ready.future;

  @override
  Future<CoreProcessStopResult> stop(Duration timeout) {
    return _stopping ??= _stop(timeout).then((result) {
      if (!result.exitConfirmed) _stopping = null;
      return result;
    });
  }

  Future<CoreProcessStopResult> _stop(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final duration = deadline.difference(DateTime.now());
      return duration.isNegative ? Duration.zero : duration;
    }

    try {
      _process.stdin.writeln('stop');
      await _process.stdin.flush().timeout(remaining());
    } catch (_) {
      // A closed control pipe still requires exit and cleanup confirmation below.
    }
    try {
      await _process.exitCode.timeout(remaining());
      await _outputDone.future.timeout(remaining());
    } on TimeoutException {
      return const CoreProcessStopResult(stopped: true, exitConfirmed: false);
    }
    if (!_clean) throw StateError('Core cleanup was not acknowledged');
    return const CoreProcessStopResult(stopped: true, exitConfirmed: true);
  }
}

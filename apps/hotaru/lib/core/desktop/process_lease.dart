import 'dart:async';
import 'dart:io';

import 'model.dart';

typedef CoreProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

final class DirectCoreLease implements CoreProcessExitSource {
  @override
  final String sessionId;

  final Process _process;
  Future<CoreProcessStopResult>? _stopOperation;

  DirectCoreLease({required this.sessionId, required Process process})
    : _process = process;

  @override
  CoreProcessOwner get owner => CoreProcessOwner.direct;

  @override
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<CoreProcessStopResult> stop(Duration timeout) {
    final stopOperation = _stopOperation;
    if (stopOperation != null) {
      return stopOperation;
    }
    final nextOperation = _stop(timeout).then((result) {
      if (!result.exitConfirmed) {
        _stopOperation = null;
      }
      return result;
    });
    _stopOperation = nextOperation;
    return nextOperation;
  }

  Future<CoreProcessStopResult> _stop(Duration timeout) async {
    final stopped = _process.kill();
    try {
      await _process.exitCode.timeout(timeout);
      return CoreProcessStopResult(stopped: stopped, exitConfirmed: true);
    } on TimeoutException {
      return CoreProcessStopResult(stopped: stopped, exitConfirmed: false);
    }
  }
}

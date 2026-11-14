import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../desktop/model.dart';
import 'host_events.dart';

final class StdioCoreLease implements CoreProcessReadySource {
  final Process _process;
  final SingBoxHostEvents _events;
  Future<CoreProcessStopResult>? _stopping;

  @override
  final String sessionId;

  StdioCoreLease({
    required this.sessionId,
    required Process process,
    void Function(String)? onStderr,
  }) : _process = process,
       _events = SingBoxHostEvents(process.pid) {
    process.stdin.done.ignore();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _events.add,
          onError: (Object error) => _events.fail(),
          onDone: _events.finish,
          cancelOnError: false,
        );
    process.stderr
        .transform(utf8.decoder)
        .listen(onStderr ?? (_) {}, onError: (Object _) {});
  }

  @override
  CoreProcessOwner get owner => CoreProcessOwner.direct;
  @override
  int get pid => _process.pid;
  @override
  Future<int> get exitCode => _process.exitCode;
  @override
  Future<void> get ready => _events.ready;

  @override
  Future<CoreProcessStopResult> stop(Duration timeout) {
    return _stopping ??= _stop(timeout).then((result) {
      if (!result.exitConfirmed) _stopping = null;
      return result;
    });
  }

  Future<CoreProcessStopResult> _stop(Duration timeout) async {
    final elapsed = Stopwatch()..start();
    Duration remaining() {
      final duration = timeout - elapsed.elapsed;
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
      await _events.finished.timeout(remaining());
    } on TimeoutException {
      return const CoreProcessStopResult(stopped: true, exitConfirmed: false);
    }
    if (!_events.clean) throw StateError('Core cleanup was not acknowledged');
    return const CoreProcessStopResult(stopped: true, exitConfirmed: true);
  }
}

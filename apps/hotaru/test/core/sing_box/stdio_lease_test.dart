import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/sing_box/stdio_lease.dart';

void main() {
  late _Process process;
  late StdioCoreLease lease;

  setUp(() {
    process = _Process();
    lease = StdioCoreLease(sessionId: 'fixture-session', process: process);
  });

  tearDown(() async {
    await process.dispose();
  });

  test(
    'requires an owned ready handshake and waits for clean engine shutdown',
    () async {
      process.event('ready');
      await lease.ready;
      process.onInput = () => process.finish(clean: true);
      final result = await lease.stop(const Duration(seconds: 1));
      expect(result.exitConfirmed, isTrue);
      expect(process.inputText, 'stop\n');
      expect(process.killCount, 0);
    },
  );

  test('a process exit alone cannot confirm network cleanup', () async {
    process.event('ready');
    await lease.ready;
    process.onInput = () => process.finish(acknowledge: false);
    await expectLater(lease.stop(const Duration(seconds: 1)), throwsStateError);
    expect(process.killCount, 0);
  });

  test(
    'failed cleanup is retained as failure even after process exit',
    () async {
      process.event('ready');
      await lease.ready;
      process.onInput = () => process.finish(clean: false);
      await expectLater(
        lease.stop(const Duration(seconds: 1)),
        throwsStateError,
      );
    },
  );

  test(
    'timeout preserves ownership without forcibly terminating the engine',
    () async {
      process.event('ready');
      await lease.ready;
      final result = await lease.stop(const Duration(milliseconds: 10));
      expect(result.exitConfirmed, isFalse);
      expect(process.killCount, 0);
      process.finish(clean: true);
      final retry = await lease.stop(const Duration(seconds: 1));
      expect(retry.exitConfirmed, isTrue);
    },
  );

  test('a mismatched PID handshake is rejected', () async {
    final rejected = expectLater(lease.ready, throwsStateError);
    process.event('ready', pid: 9999);
    await rejected;
    process.onInput = () => process.finish(clean: true);
    await expectLater(lease.stop(const Duration(seconds: 1)), throwsStateError);
  });

  test(
    'startup failure can confirm cleanup without publishing ready',
    () async {
      final rejected = expectLater(lease.ready, throwsStateError);
      process.finish(clean: true);
      await rejected;
      expect(
        (await lease.stop(const Duration(seconds: 1))).exitConfirmed,
        isTrue,
      );
    },
  );

  test(
    'does not accept cleanup before remaining control output is drained',
    () async {
      process.event('ready');
      await lease.ready;
      process.onInput = () => process.exited.complete(0);
      var completed = false;
      final stopping = lease.stop(const Duration(seconds: 1)).then((result) {
        completed = true;
        return result;
      });
      await pumpEventQueue();
      expect(completed, isFalse);
      process.event('stopped', clean: true);
      await process.output.close();
      expect((await stopping).exitConfirmed, isTrue);
    },
  );
}

final class _Input implements StreamConsumer<List<int>> {
  final void Function(List<int>) onData;
  _Input(this.onData);

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(onData);
  @override
  Future<void> close() async {}
}

final class _Process implements Process {
  final StreamController<List<int>> output = StreamController();
  final StreamController<List<int>> errors = StreamController();
  final Completer<int> exited = Completer<int>();
  String inputText = '';
  void Function()? onInput;
  int killCount = 0;
  late final IOSink input = IOSink(
    _Input((bytes) {
      inputText += utf8.decode(bytes);
      onInput?.call();
    }),
  );

  void event(String name, {bool? clean, int? pid}) {
    output.add(
      utf8.encode(
        '${jsonEncode({'protocol': 'hotaru-stdio-v1', 'event': name, 'pid': pid ?? this.pid, 'clean': ?clean})}\n',
      ),
    );
  }

  void finish({bool clean = true, bool acknowledge = true}) {
    if (acknowledge) event('stopped', clean: clean);
    unawaited(output.close());
    if (!exited.isCompleted) exited.complete(0);
  }

  Future<void> dispose() async {
    await input.close();
    if (!output.isClosed) await output.close();
    if (!errors.isClosed) await errors.close();
    if (!exited.isCompleted) exited.complete(0);
  }

  @override
  int get pid => 4321;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  IOSink get stdin => input;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCount++;
    return true;
  }
}

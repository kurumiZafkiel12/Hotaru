// Run the production lifecycle state machine with only the standalone Dart SDK.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import '../lib/core/adapter.dart';
import '../lib/core/desktop/model.dart';
import '../lib/core/sing_box/desktop_core.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final environment = Platform.environment;
  final executable = environment['HOTARU_PROBE_BINARY']!;
  final configPath = environment['HOTARU_PROBE_CONFIG']!;
  final endpoint = Uri.parse(environment['HOTARU_PROBE_API']!);
  final secret = environment['HOTARU_PROBE_SECRET']!;
  final core = SingBoxDesktopCore(
    executable: executable,
    configPath: configPath,
    endpoint: endpoint,
    secret: secret,
  );
  try {
    final started = await Future.wait([core.start(), core.start()]);
    final first = started.last.session!;
    require(
      started.every((result) => result.session?.sessionId == first.sessionId),
      'Concurrent starts launched distinct sessions',
    );
    require(
      started.any((result) => result.outcome == CoreLifecycleOutcome.coalesced),
      'Concurrent start was not coalesced',
    );
    require(
      (await core.adapter.outbounds()).any((node) => node.name == 'node-b'),
      'Core adapter is not usable after lifecycle start',
    );
    final measured = await core.adapter.delay(
      'node-b',
      Uri.parse(environment['HOTARU_PROBE_TARGET']!),
      const Duration(seconds: 3),
    );
    require(measured.inMilliseconds > 0, 'No controlled HTTPS delay result');
    final restarted = await core.restart();
    require(
      restarted.session!.sessionId != first.sessionId,
      'Restart reused the old session',
    );
    await (first.lease as CoreProcessExitSource).exitCode;
    final crash = core.lifecycle.crashEvents.first.timeout(
      const Duration(seconds: 5),
    );
    await restarted.session!.lease.stop(const Duration(seconds: 3));
    await crash;
    require(
      core.lifecycle.state is DesktopCoreFailed,
      'Unexpected process exit was not observed',
    );
    await core.start();
    final stoppedLease =
        (core.lifecycle.state as DesktopCoreRunning).session.lease;
    await Future.wait([core.restart(), core.stop()]);
    require(
      core.lifecycle.state is DesktopCoreIdle,
      'Latest stop intent did not win',
    );
    await (stoppedLease as CoreProcessExitSource).exitCode;
    try {
      await core.adapter.outbounds();
      throw StateError('Stopped adapter still accepts requests');
    } on CoreAdapterException catch (error) {
      require(
        error.code == 'core_not_running',
        'Wrong stopped adapter outcome',
      );
    }
    final closing = core.close();
    require(identical(closing, core.close()), 'Close is not idempotent');
    await closing;
    require(
      core.lifecycle.state is DesktopCoreClosed,
      'Close was not terminal',
    );
    final directory = await Directory.systemTemp.createTemp(
      'hotaru-invalid-core-',
    );
    try {
      final invalid =
          jsonDecode(await File(configPath).readAsString())
              as Map<String, dynamic>;
      (invalid['outbounds'] as List).first['type'] = 'hotaru-invalid-protocol';
      final file = await File(
        '${directory.path}/config.json',
      ).writeAsString(jsonEncode(invalid));
      final failing = SingBoxDesktopCore(
        executable: executable,
        configPath: file.path,
        endpoint: endpoint,
        secret: secret,
      );
      try {
        var rejected = false;
        try {
          await failing.start();
        } on DesktopCoreFailure {
          rejected = true;
        }
        require(
          rejected && failing.lifecycle.state is DesktopCoreFailed,
          'Invalid core configuration was not rejected',
        );
      } finally {
        await failing.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
    stdout.writeln(
      jsonEncode({
        'desktopLifecycle': 'passed',
        'windowsPeerPidVerified': Platform.isWindows,
        'nodeSpecificDelayMs': measured.inMilliseconds,
      }),
    );
  } finally {
    await core.close();
  }
}

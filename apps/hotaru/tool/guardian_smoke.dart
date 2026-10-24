// Destructive registry tests MUST only run in an ephemeral Windows CI account.
import 'dart:async';
import 'dart:io';

import 'package:hotaru/platform/system_proxy.dart';
import 'package:hotaru/core/mihomo_controller.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || Platform.environment['GITHUB_ACTIONS'] != 'true') {
    throw StateError('Requires isolated Windows GitHub Actions runner');
  }
  final guardian = File(args.single).absolute.path;
  final adapter = WindowsSystemProxy();
  final original = await adapter.read();
  final baseline = const SavedProxyState(
    enable: false,
    server: 'original.example:8080',
  );
  const owned = '127.0.0.1:17890';
  final children = <Process>[];
  Future<Process> sleeper() async {
    final p = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Start-Sleep -Seconds 120',
    ]);
    unawaited(p.stdout.drain<void>());
    unawaited(p.stderr.drain<void>());
    children.add(p);
    return p;
  }

  Future<void> eventually(SavedProxyState state) async {
    for (var i = 0; i < 100; i++) {
      final current = await adapter.read();
      if (current.encode() == state.encode()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError(
      'Guardian did not restore expected proxy values: expected=${state.encode()}, actual=${(await adapter.read()).encode()}',
    );
  }

  try {
    for (final scenario in ['parent', 'core', 'cancel', 'foreign', 'absent']) {
      final before = scenario == 'absent' ? const SavedProxyState() : baseline;
      await adapter.restore(before);
      await eventually(before);
      final parent = await sleeper(), core = await sleeper();
      final token = MihomoController.newSecret().replaceAll(
        RegExp('[^a-zA-Z0-9-]'),
        '',
      );
      final armed = await Process.run(guardian, [
        'arm',
        token,
        '${parent.pid}',
        '${core.pid}',
        owned,
      ]);
      if (armed.exitCode != 0) {
        throw StateError('Guardian failed readiness: ${armed.exitCode}');
      }
      await adapter.enable(owned);
      if (scenario == 'cancel') {
        final result = await Process.run(guardian, ['cancel', token]);
        if (result.exitCode != 0) throw StateError('Cancel failed');
      }
      if (scenario == 'foreign') await adapter.enable('new.example:8081');
      (scenario == 'core' ? core : parent).kill();
      await (scenario == 'core' ? core : parent).exitCode;
      if (scenario == 'cancel' || scenario == 'foreign') {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await eventually(
          SavedProxyState(
            enable: true,
            server: scenario == 'cancel' ? owned : 'new.example:8081',
          ),
        );
      } else {
        await eventually(before);
      }
      parent.kill();
      core.kill();
      stdout.writeln('PASS guardian $scenario');
    }
  } finally {
    for (final child in children) {
      child.kill();
      await child.exitCode;
    }
    await adapter.restore(original);
  }
}

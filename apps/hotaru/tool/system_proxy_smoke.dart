// Run ONLY on the isolated Windows CI runner: briefly changes its HKCU proxy.
import 'dart:io';

import 'package:hotaru/platform/system_proxy.dart';

Future<void> main() async {
  if (!Platform.isWindows || Platform.environment['GITHUB_ACTIONS'] != 'true') {
    throw StateError(
      'This test is restricted to the isolated Windows CI runner',
    );
  }
  final adapter = WindowsSystemProxy();
  final original = await adapter.read();
  try {
    await adapter.enable('127.0.0.1:19999');
    final current = await adapter.read();
    if (current.enable != true || current.server != '127.0.0.1:19999') {
      throw StateError('System proxy write/read mismatch');
    }
  } finally {
    await adapter.restore(original);
  }
  if ((await adapter.read()).encode() != original.encode()) {
    throw StateError('Original system proxy was not restored');
  }
  stdout.writeln(
    'PASS: real HKCU proxy enable, WinINet refresh, exact restore',
  );
}

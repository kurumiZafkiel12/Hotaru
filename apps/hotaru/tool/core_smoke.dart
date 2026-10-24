import 'dart:io';

import 'package:hotaru/core/mihomo_controller.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass absolute Mihomo executable path');
  }
  final directory = await Directory.systemTemp.createTemp('hotaru-smoke-');
  final core = MihomoController();
  try {
    await core.startDiagnostic(args.single, directory, 19091);
    if (core.status != CoreStatus.running) {
      throw StateError('Health check failed');
    }
    await core.stop();
    if (core.status != CoreStatus.stopped) throw StateError('Stop failed');
    stdout.writeln('PASS: validate, start, authenticated health check, stop');
  } finally {
    await core.dispose();
    await directory.delete(recursive: true);
  }
}

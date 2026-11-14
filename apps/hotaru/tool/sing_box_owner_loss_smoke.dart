// Intentionally exit the owned Dart parent to test kernel cleanup after process loss.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import '../lib/core/sing_box/desktop_core.dart';

Future<void> main() async {
  final environment = Platform.environment;
  if (!Platform.isWindows || environment['CI'] != 'true') {
    throw StateError('Owner-loss probe is restricted to disposable Windows CI');
  }
  final core = SingBoxDesktopCore(
    executable: environment['HOTARU_PROBE_BINARY']!,
    configPath: environment['HOTARU_PROBE_CONFIG']!,
    endpoint: Uri.parse(environment['HOTARU_PROBE_API']!),
    secret: environment['HOTARU_PROBE_SECRET']!,
    stdioControl: true,
    onStderr: stderr.write,
  );
  final started = await core.start();
  stdout.writeln(
    jsonEncode({'event': 'owner_ready', 'pid': started.session!.pid}),
  );
  await stdout.flush();
  exit(17);
}

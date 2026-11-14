import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../desktop/model.dart';
import '../desktop/process_lease.dart';
import 'stdio_lease.dart';

final class SingBoxLauncher implements CoreProcessLauncher {
  final String executable;
  final String configPath;
  final Uri endpoint;
  final String _secret;
  final CoreProcessStarter _start;
  final bool stdioControl;
  final void Function(String)? onStderr;

  SingBoxLauncher({
    required this.executable,
    required this.configPath,
    required this.endpoint,
    required String secret,
    CoreProcessStarter? startProcess,
    this.stdioControl = false,
    this.onStderr,
  }) : _secret = secret,
       _start = startProcess ?? Process.start;

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    if (address != endpoint.toString()) {
      throw StateError('Controller address mismatch');
    }
    final Map<String, dynamic> config;
    try {
      config =
          jsonDecode(await File(configPath).readAsString())
              as Map<String, dynamic>;
    } on FormatException {
      throw StateError('Invalid compiled core configuration');
    } on TypeError {
      throw StateError('Invalid compiled core configuration');
    }
    final experimental = config['experimental'];
    final controller = experimental is Map ? experimental['clash_api'] : null;
    final binding =
        '${endpoint.host.contains(':') ? '[${endpoint.host}]' : endpoint.host}:${endpoint.port}';
    if (controller is! Map ||
        controller['external_controller'] != binding ||
        controller['secret'] != _secret) {
      throw StateError(
        'Compiled controller does not match session credentials',
      );
    }
    final inbounds = config['inbounds'];
    if (Platform.isWindows &&
        !stdioControl &&
        inbounds is List &&
        inbounds.any((entry) => entry is Map && entry['type'] == 'tun')) {
      throw StateError('Windows TUN requires the graceful desktop host');
    }
    final process = await _start(executable, [
      'run',
      '-c',
      configPath,
      if (stdioControl) '--stdio-control',
    ]);
    if (stdioControl) {
      return StdioCoreLease(
        sessionId: sessionId,
        process: process,
        onStderr: onStderr,
      );
    }
    unawaited(process.stdout.drain<void>().catchError((Object _) {}));
    unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    return DirectCoreLease(sessionId: sessionId, process: process);
  }
}

final class SingBoxLauncherResolver implements DesktopCoreLauncherResolver {
  final SingBoxLauncher launcher;

  const SingBoxLauncherResolver(this.launcher);

  @override
  Future<CoreProcessLauncher> resolve() async => launcher;
}

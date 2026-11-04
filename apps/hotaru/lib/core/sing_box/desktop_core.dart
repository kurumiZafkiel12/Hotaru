import 'dart:io';

import '../adapter.dart';
import '../desktop/lifecycle.dart';
import '../desktop/model.dart';
import 'clash_api_adapter.dart';
import 'controller_connection.dart';
import 'launcher.dart';
import 'session_adapter.dart';

final class SingBoxDesktopCore {
  final DesktopCoreLifecycleController lifecycle;
  final CoreAdapter adapter;
  Future<CoreLifecycleResult>? _closing;

  SingBoxDesktopCore._(this.lifecycle, this.adapter);

  factory SingBoxDesktopCore({
    required String executable,
    required String configPath,
    required Uri endpoint,
    required String secret,
    DesktopCoreTimeouts timeouts = const DesktopCoreTimeouts(
      connection: Duration(seconds: 20),
    ),
  }) {
    final lifecycle = DesktopCoreLifecycle(
      transportFactory: () =>
          SingBoxControllerConnection(endpoint: endpoint, secret: secret),
      launcherResolver: SingBoxLauncherResolver(
        SingBoxLauncher(
          executable: executable,
          configPath: configPath,
          endpoint: endpoint,
          secret: secret,
        ),
      ),
      verifyPeerPid: Platform.isWindows,
      timeouts: timeouts,
    );
    return SingBoxDesktopCore._(
      lifecycle,
      SessionCoreAdapter(
        lifecycle: lifecycle,
        factory: () =>
            SingBoxClashApiAdapter(endpoint: endpoint, secret: secret),
      ),
    );
  }

  Future<CoreLifecycleResult> start() => lifecycle.start();
  Future<CoreLifecycleResult> restart() => lifecycle.restart();
  Future<CoreLifecycleResult> stop() => lifecycle.stop();

  Future<CoreLifecycleResult> close() => _closing ??= _close();

  Future<CoreLifecycleResult> _close() async {
    try {
      return await lifecycle.close();
    } finally {
      await adapter.close();
    }
  }
}

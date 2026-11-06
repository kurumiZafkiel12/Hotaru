import 'dart:io';

import '../adapter.dart';
import '../desktop/lifecycle.dart';
import '../desktop/model.dart';
import 'clash_api_adapter.dart';
import 'controller_connection.dart';
import 'config_preparation.dart';
import 'launcher.dart';
import 'session_adapter.dart';

abstract interface class SingBoxConfigurationBinding {
  AcceptedSingBoxConfig get current;
  CoreAdapter createAdapter();
  Future<CoreLifecycleResult> apply(AcceptedSingBoxConfig configuration);
}

final class SingBoxDesktopCore {
  final DesktopCoreLifecycleController lifecycle;
  final CoreAdapter adapter;
  final SingBoxConfigurationBinding? _configuration;
  Future<CoreLifecycleResult>? _closing;

  SingBoxDesktopCore._(this.lifecycle, this.adapter, [this._configuration]);

  factory SingBoxDesktopCore.withConfiguration({
    required DesktopCoreLifecycleController lifecycle,
    required SingBoxConfigurationBinding configuration,
  }) => SingBoxDesktopCore._(
    lifecycle,
    SessionCoreAdapter(
      lifecycle: lifecycle,
      factory: configuration.createAdapter,
    ),
    configuration,
  );

  AcceptedSingBoxConfig? get configuration => _configuration?.current;

  Future<CoreLifecycleResult> applyConfiguration(
    AcceptedSingBoxConfig configuration,
  ) {
    final binding = _configuration;
    if (binding == null) {
      return Future.error(
        UnsupportedError('This core has no configuration binding'),
      );
    }
    return binding.apply(configuration);
  }

  factory SingBoxDesktopCore({
    required String executable,
    required String configPath,
    required Uri endpoint,
    required String secret,
    bool stdioControl = false,
    void Function(String)? onStderr,
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
          stdioControl: stdioControl,
          onStderr: onStderr,
        ),
      ),
      verifyPeerPid: Platform.isWindows,
      timeouts: timeouts,
    );
    return SingBoxDesktopCore.withLifecycle(
      lifecycle: lifecycle,
      endpoint: endpoint,
      secret: secret,
    );
  }

  factory SingBoxDesktopCore.withLifecycle({
    required DesktopCoreLifecycleController lifecycle,
    required Uri endpoint,
    required String secret,
  }) => SingBoxDesktopCore._(
    lifecycle,
    SessionCoreAdapter(
      lifecycle: lifecycle,
      factory: () => SingBoxClashApiAdapter(endpoint: endpoint, secret: secret),
    ),
  );

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

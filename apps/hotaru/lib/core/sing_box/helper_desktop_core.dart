import 'dart:io';

import 'package:path/path.dart' as p;

import '../../common/constant.dart';
import '../config/profile.dart';
import '../desktop/helper_client.dart';
import '../desktop/core_manifest.dart';
import '../desktop/lifecycle.dart';
import '../desktop/model.dart';
import '../desktop/transport.dart';
import 'config_builder.dart';
import 'controller_connection.dart';
import 'desktop_core.dart';
import 'pipe_connection.dart';

Future<SingBoxDesktopCore> createSingBoxHelperCore({
  required CoreProfileSpec profile,
  required CoreListenerSpec listeners,
  String? bundleDirectory,
  DesktopCoreTimeouts timeouts = const DesktopCoreTimeouts(
    connection: Duration(seconds: 20),
  ),
}) async {
  if (!Platform.isWindows || safeModeBuild) {
    throw StateError('Privileged sing-box requires Windows outside safe mode');
  }
  final directory = p.normalize(
    p.absolute(bundleDirectory ?? p.dirname(Platform.resolvedExecutable)),
  );
  final digest = await CoreManifest.readSingBoxHostSha256(
    path: p.join(directory, coreManifestName),
  );
  if (digest == null) {
    throw StateError('Matching sing-box host manifest is missing');
  }
  final helper = HelperClient(
    readCoreSha256: () async => digest,
    expectedHelperPath: () => p.join(directory, '$appHelperService.exe'),
  );
  final built = await SingBoxConfigBuilder().build(profile, listeners);
  final config = built.json;
  if (config == null) throw StateError('Invalid sing-box profile');
  final endpoint = Uri.parse('http://127.0.0.1:${listeners.controllerPort}');
  late SingBoxPipeConnection connection;
  SingBoxPipeConnection transportFactory() {
    return connection = SingBoxPipeConnection(
      pipe: IpcCoreTransport(
        address: '\\\\.\\pipe\\HotaruCore_${createCoreSessionId()}',
      ),
      controller: SingBoxControllerConnection(
        endpoint: endpoint,
        secret: listeners.secret,
      ),
      compiledConfig: config,
    );
  }

  final lifecycle = DesktopCoreLifecycle(
    transportFactory: transportFactory,
    launcherResolver: _HelperResolver(helper, () => connection),
    verifyPeerPid: true,
    timeouts: timeouts,
  );
  return SingBoxDesktopCore.withLifecycle(
    lifecycle: lifecycle,
    endpoint: endpoint,
    secret: listeners.secret,
  );
}

final class _HelperResolver implements DesktopCoreLauncherResolver {
  final HelperClient helper;
  final SingBoxPipeConnection Function() connection;

  const _HelperResolver(this.helper, this.connection);

  @override
  Future<CoreProcessLauncher> resolve() async {
    if (await helper.readiness() != HelperReadiness.ready) {
      throw StateError('Matching privileged sing-box Helper is unavailable');
    }
    return _HelperLauncher(HelperLauncher(helper), connection());
  }
}

final class _HelperLauncher implements CoreProcessLauncher {
  final CoreProcessLauncher launcher;
  final SingBoxPipeConnection connection;

  const _HelperLauncher(this.launcher, this.connection);

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    if (address != connection.address) throw StateError('Host pipe changed');
    final process = await launcher.start(
      sessionId: sessionId,
      address: address,
    );
    return SingBoxPipeLease(process: process, connection: connection);
  }
}

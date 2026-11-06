import 'dart:io';

import 'package:path/path.dart' as p;

import '../../common/constant.dart';
import '../adapter.dart';
import '../desktop/helper_client.dart';
import '../desktop/core_manifest.dart';
import '../desktop/lifecycle.dart';
import '../desktop/listener_owner.dart';
import '../desktop/model.dart';
import '../desktop/transport.dart';
import 'clash_api_adapter.dart';
import 'config_preparation.dart';
import 'controller_connection.dart';
import 'desktop_core.dart';
import 'pipe_connection.dart';

Future<SingBoxDesktopCore> createSingBoxHelperCore({
  required AcceptedSingBoxConfig configuration,
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
  final plan = _HelperPlan(helper, configuration);
  final lifecycle = DesktopCoreLifecycle.withPlan(
    plan: plan,
    verifyPeerPid: true,
    timeouts: timeouts,
  );
  return SingBoxDesktopCore.withConfiguration(
    lifecycle: lifecycle,
    configuration: _HelperConfiguration(lifecycle, helper),
  );
}

final class _HelperConfiguration implements SingBoxConfigurationBinding {
  final DesktopCoreLifecycle lifecycle;
  final HelperClient helper;

  const _HelperConfiguration(this.lifecycle, this.helper);

  @override
  AcceptedSingBoxConfig get current =>
      (lifecycle.committedPlan as _HelperPlan).configuration;

  @override
  CoreAdapter createAdapter() {
    final configuration = (lifecycle.activePlan as _HelperPlan).configuration;
    final listeners = configuration.listeners;
    return SingBoxClashApiAdapter(
      endpoint: Uri.parse('http://127.0.0.1:${listeners.controllerPort}'),
      secret: listeners.secret,
      telemetry: (lifecycle.activePlan as _HelperPlan).connection().telemetry,
      probe: listeners.probe,
      probeOutbounds: [
        ...configuration.profile.nodes.map((node) => node.tag),
        ...configuration.profile.selectors.map((group) => group.tag),
      ],
    );
  }

  @override
  Future<CoreLifecycleResult> apply(AcceptedSingBoxConfig configuration) =>
      lifecycle.applyConfiguration(_HelperPlan(helper, configuration));
}

final class _HelperPlan extends DesktopCoreLaunchPlan {
  final AcceptedSingBoxConfig configuration;
  final SingBoxPipeConnection Function() connection;

  const _HelperPlan._({
    required this.configuration,
    required this.connection,
    required super.transportFactory,
    required super.launcherResolver,
  });

  factory _HelperPlan(
    HelperClient helper,
    AcceptedSingBoxConfig configuration,
  ) {
    final listeners = configuration.listeners;
    final endpoint = Uri.parse('http://127.0.0.1:${listeners.controllerPort}');
    late SingBoxPipeConnection connection;
    SingBoxPipeConnection transportFactory() =>
        connection = SingBoxPipeConnection(
          pipe: IpcCoreTransport(
            address: r'\\.\pipe\HotaruCore_' + createCoreSessionId(),
          ),
          controller: SingBoxControllerConnection(
            endpoint: endpoint,
            secret: listeners.secret,
            peerPid: () async {
              final owners = await Future.wait([
                windowsListenerOwner(endpoint),
                if (listeners.probe case final probe?)
                  windowsListenerOwner(
                    Uri.parse('http://127.0.0.1:${probe.port}'),
                  ),
              ]);
              final owner = owners.first;
              return owner != null && owners.every((pid) => pid == owner)
                  ? owner
                  : null;
            },
          ),
          bootstrap: configuration.bootstrap,
        );
    return _HelperPlan._(
      configuration: configuration,
      connection: () => connection,
      transportFactory: transportFactory,
      launcherResolver: _HelperResolver(helper, () => connection),
    );
  }
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

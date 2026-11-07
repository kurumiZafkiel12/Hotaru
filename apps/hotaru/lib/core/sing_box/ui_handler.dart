import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../models/models.dart';
import '../../common/common.dart';
import '../../enum/enum.dart';
import '../adapter.dart';
import '../config/mode_outbounds.dart';
import '../desktop/model.dart';
import '../interface.dart';
import '../method.dart';
import '../outbound_http.dart';
import '../telemetry.dart';
import '../event.dart';
import '../routing_mode.dart';
import '../profile_documents.dart';
import 'desktop_core.dart';
import 'ui_routes.dart';

final class SingBoxUiHandler extends CoreHandlerInterface
    implements
        CoreOutboundHttpClients,
        CoreRoutingModes,
        CoreProfileTextBuilder {
  final SingBoxDesktopCore core;
  late final SingBoxUiRoutes _routes;
  late final StreamSubscription<DesktopCoreFailure> _crashes;
  Future<CoreLifecycleResult>? _closing;

  SingBoxUiHandler(this.core, {void Function(CoreEvent)? onEvent}) {
    if (core.configuration == null) {
      throw ArgumentError('A prepared sing-box configuration is required');
    }
    final publish = onEvent ?? coreEventManager.sendEvent;
    _routes = SingBoxUiRoutes(
      core: core,
      onChange: (snapshot) => publish(
        CoreEvent(type: CoreEventType.routeChanged, data: snapshot.toJson()),
      ),
      onError: (error, _) => commonPrint.log(
        'sing-box route watch failed: ${error is CoreAdapterException ? error.code : 'failed'}',
        logLevel: LogLevel.debug,
      ),
    );
    _crashes = core.lifecycle.crashEvents.listen(
      (failure) =>
          publish(CoreEvent(type: CoreEventType.crash, data: failure.code)),
    );
  }

  String _session() {
    final state = core.lifecycle.state;
    if (state is! DesktopCoreRunning) {
      throw const CoreAdapterException('core_not_running');
    }
    return state.session.sessionId;
  }

  void _checkSession(String id) {
    if (_session() != id) {
      throw const CoreAdapterException('session_changed');
    }
  }

  @override
  Future<CoreLifecycleResult> start() => core.start();
  @override
  Future<CoreLifecycleResult> restart() => core.restart();
  @override
  Future<CoreLifecycleResult> stop() => core.stop();
  @override
  Future<CoreLifecycleResult> close() => _closing ??= _close();

  Future<CoreLifecycleResult> _close() async {
    try {
      return await core.close();
    } finally {
      await _routes.close();
      await _crashes.cancel();
    }
  }

  @override
  Future<RouteSnapshot> watchRoute(bool watch) => _routes.watch(watch);

  @override
  Future<ChangeProxyResult> changeProxy(ChangeProxyParams changeProxyParams) {
    if (changeProxyParams.forSpeedTest) {
      return Future.error(
        const CoreMethodException(
          code: 'scoped_client_required',
          message: 'Node speed tests require scoped HTTP clients',
        ),
      );
    }
    return _routes.select(
      changeProxyParams.groupName,
      changeProxyParams.proxyName,
    );
  }

  @override
  Future<CoreRoutingMode> routingMode() => _routes.mode();

  @override
  Future<void> setRoutingMode(CoreRoutingMode mode) => _routes.setMode(mode);

  @override
  Future<bool> get isInit async => core.lifecycle.state is DesktopCoreRunning;

  @override
  Future<bool> init(InitParams params) => isInit;

  @override
  Future<Map<String, dynamic>> getConfig(String path) =>
      CoreProfileDocuments.read(path);

  @override
  Future<ProfileBase> getProfileBase(String path) =>
      CoreProfileDocuments.base(path);

  @override
  Future<Map<String, dynamic>> getProfileOutbounds(String path) =>
      CoreProfileDocuments.outbounds(path);

  @override
  Future<String> buildProfileText(SetupBase base) =>
      CoreProfileDocuments.build(base);

  @override
  Future<ProxiesData> getProxies() async {
    final session = _session();
    final configuration = core.configuration;
    if (configuration == null) {
      throw const CoreAdapterException('applied_profile_unavailable');
    }
    final nodes = await core.adapter.outbounds();
    if (!identical(configuration, core.configuration)) {
      throw const CoreAdapterException('session_changed');
    }
    final profile = configuration.profile;
    final result = await Isolate.run(() {
      final modes = CoreModeOutbounds(profile);
      final ownsGlobal =
          profile.nodes.any((node) => node.tag == 'GLOBAL') ||
          profile.selectors.any((group) => group.tag == 'GLOBAL');
      final shown = nodes
          .where((node) => node.name != 'GLOBAL' || ownsGlobal)
          .toList();
      return ProxiesData(
        all: shown.map((node) => node.name).toList(),
        proxies: {
          for (final node in shown)
            node.name: {
              'name': node.name,
              'type': node.type,
              if (node.members.isNotEmpty) 'all': node.members,
              if (node.selected != null) 'now': node.selected,
              if (node.name == modes.global.tag) 'hidden': true,
            },
        },
      );
    });
    _checkSession(session);
    return result;
  }

  @override
  Future<Delay> asyncTestDelay(
    String url,
    String proxyName,
    Duration timeout,
  ) async {
    final value = await core.adapter.delay(proxyName, Uri.parse(url), timeout);
    return Delay(
      name: proxyName,
      url: url,
      value: value.inMilliseconds,
      elapsedMs: value.inMilliseconds,
    );
  }

  @override
  Future<List<TrackerInfo>> getConnections() async {
    final session = _session();
    final source = core.adapter;
    if (source is! CoreTelemetry) {
      throw const CoreAdapterException('telemetry_unavailable');
    }
    final sample = await (source as CoreTelemetry).telemetry();
    if (sample.activeTruncated) {
      throw const CoreAdapterException('connection_window_truncated');
    }
    final result = await Isolate.run(
      () => [
        for (final entry in sample.active)
          TrackerInfo(
            id: entry.id,
            start: entry.createdAt,
            upload: entry.upload,
            download: entry.download,
            metadata: Metadata(
              network: entry.network,
              sourceIP: entry.sourceIp,
              sourcePort: '${entry.sourcePort}',
              destinationIP: entry.destinationIp,
              destinationPort: '${entry.destinationPort}',
              host: entry.host,
              processPath: entry.processPath,
              process: entry.processPath.split(RegExp(r'[/\\]')).last,
            ),
            chains: entry.chain,
            rule: entry.rule,
            rulePayload: '',
          ),
      ],
    );
    _checkSession(session);
    return result;
  }

  @override
  Future<int> getConnectionCount() async =>
      (await core.adapter.connections()).entries.length;

  @override
  Future<bool> closeConnection(String id) async {
    await core.adapter.closeConnection(id);
    return true;
  }

  CoreOutboundHttpClients get _http {
    final source = core.adapter;
    if (source is! CoreOutboundHttpClients) {
      throw const CoreAdapterException('outbound_http_unavailable');
    }
    return source as CoreOutboundHttpClients;
  }

  @override
  Future<T> withOutboundClient<T>(
    String outbound,
    Future<T> Function(HttpClient client) action, {
    Duration timeout = const Duration(minutes: 2),
  }) => _http.withOutboundClient(outbound, action, timeout: timeout);

  @override
  Future<T> withOutboundClients<T>(
    String outbound,
    Future<T> Function(CoreOutboundClients clients) action, {
    Duration timeout = const Duration(minutes: 2),
  }) => _http.withOutboundClients(outbound, action, timeout: timeout);

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) => Future.error(
    CoreMethodException(
      code: 'sing_box_method_unavailable',
      message: 'sing-box UI bridge does not yet implement ${method.name}',
    ),
  );
}

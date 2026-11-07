import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../models/models.dart';
import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../l10n/l10n.dart';
import '../adapter.dart';
import '../config/mode_outbounds.dart';
import '../config/share_links.dart';
import '../config/proxy_definitions.dart';
import '../config/node_definition.dart';
import '../config/share_link_encoder.dart';
import '../desktop/model.dart';
import '../interface.dart';
import '../method.dart';
import '../outbound_http.dart';
import '../telemetry.dart';
import '../maintenance.dart';
import '../event.dart';
import '../routing_mode.dart';
import '../profile_documents.dart';
import 'desktop_core.dart';
import 'config_preparation.dart';
import 'ui_routes.dart';
import 'ui_traffic.dart';

final class SingBoxUiHandler extends CoreHandlerInterface
    implements
        CoreOutboundHttpClients,
        CoreRoutingModes,
        CoreGlobalOutbound,
        CoreProfileTextBuilder {
  final SingBoxDesktopCore core;
  late final SingBoxUiRoutes _routes;
  late final SingBoxUiTraffic _traffic;
  late final StreamSubscription<DesktopCoreFailure> _crashes;
  Future<CoreLifecycleResult>? _closing;

  SingBoxUiHandler(
    this.core, {
    void Function(CoreEvent)? onEvent,
    Duration Function()? trafficElapsed,
  }) {
    if (core.configuration == null) {
      throw ArgumentError('A prepared sing-box configuration is required');
    }
    final publish = onEvent ?? coreEventManager.sendEvent;
    _traffic = SingBoxUiTraffic(core: core, elapsed: trafficElapsed);
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
  Future<CoreLifecycleResult> restart() => _routes.restart();
  @override
  Future<CoreLifecycleResult> stop() => core.stop();
  @override
  Future<CoreLifecycleResult> close() => _closing ??= _close();

  Future<CoreLifecycleResult> _close() async {
    try {
      return await core.close();
    } finally {
      await _routes.close();
      await _traffic.close();
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
  Future<String> globalOutbound() async {
    final configuration = core.configuration;
    if (configuration == null) {
      throw const CoreAdapterException('applied_profile_unavailable');
    }
    final profile = configuration.profile;
    final tag = await Isolate.run(() => CoreModeOutbounds(profile).global.tag);
    if (!identical(configuration, core.configuration)) {
      throw const CoreAdapterException('session_changed');
    }
    return tag;
  }

  @override
  Future<bool> startListener() => _routes.setInbounds(true);

  @override
  Future<bool> stopListener() => _routes.setInbounds(false);

  Future<CoreLifecycleResult> applyConfiguration(
    AcceptedSingBoxConfig configuration,
  ) => _routes.applyConfiguration(configuration);

  @override
  Future<bool> get isInit async => core.lifecycle.state is DesktopCoreRunning;

  @override
  Future<bool> init(InitParams params) => isInit;

  @override
  Future<Traffic> getTraffic(bool onlyStatisticsProxy) =>
      _traffic.speed(onlyStatisticsProxy);

  @override
  Future<Traffic> getTotalTraffic(bool onlyStatisticsProxy) =>
      _traffic.total(onlyStatisticsProxy);

  @override
  Future<void> resetTraffic() => _traffic.reset();

  @override
  Future<CoreMemoryStats?> getMemoryStats() async {
    final session = _session();
    final source = core.adapter;
    if (source is! CoreTelemetry) {
      throw const CoreAdapterException('telemetry_unavailable');
    }
    final sample = await (source as CoreTelemetry).telemetry();
    _checkSession(session);
    final memory = sample.memory;
    if (memory == null || memory.rss == 0) return null;
    return CoreMemoryStats(
      rss: memory.rss,
      heapInuse: memory.heapInuse,
      heapIdle: memory.heapIdle,
      stackInuse: memory.stackInuse,
      runtimeOther: memory.runtimeOther,
    );
  }

  @override
  Future<bool> forceGc() async {
    await (core.adapter as CoreRuntimeMaintenance).collectMemory();
    return true;
  }

  @override
  Future<bool> resetConnections() async {
    await (core.adapter as CoreRuntimeMaintenance).resetDnsConnections();
    return true;
  }

  @override
  Future<bool> closeConnections() async {
    await (core.adapter as CoreConnectionMaintenance).closeConnections();
    return true;
  }

  @override
  Future<bool> clearDnsCache() async {
    await (core.adapter as CoreConnectionMaintenance).clearDnsCache();
    return true;
  }

  @override
  Future<Map<String, dynamic>> getConfig(String path) =>
      CoreProfileDocuments.read(path);

  @override
  Future<String> validateConfig(String path) async {
    try {
      await CoreProfileDocuments.read(path);
      return '';
    } on Exception {
      return AppLocalizations.current.importConfigInvalid;
    }
  }

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
  Future<List<Map<String, dynamic>>> convertProxies(String path) async =>
      _shareNodes(
        await CoreShareLinks.decode(await CoreProfileDocuments.readText(path)),
      );

  @override
  Future<List<String>> validateProxies(List<Map<String, dynamic>> proxies) =>
      CoreProxyDefinitions.validate(proxies);

  @override
  Future<List<String>> encodeShareLinks(List<Map<String, dynamic>> proxies) =>
      CoreShareLinkEncoder.encode(proxies);

  @override
  Future<Map<String, dynamic>?> getProxyDefinition(String name) async {
    final session = _session();
    final configuration = core.configuration!;
    final node = await CoreNodeDefinition.find(configuration.profile, name);
    _checkSession(session);
    if (!identical(configuration, core.configuration)) {
      throw const CoreAdapterException('session_changed');
    }
    return node;
  }

  @override
  Future<List<List<Map<String, dynamic>>>> decodeShareLinks(
    List<String> lines,
  ) async => _shareBatchNodes(await CoreShareLinks.decodeMany(lines));

  static Future<List<List<Map<String, dynamic>>>> _shareBatchNodes(
    List<CoreShareLinkBatch> batches,
  ) => Isolate.run(
    () => [
      for (var index = 0; index < batches.length; index++)
        _shareNodes(batches[index], inputIndex: index),
    ],
  );

  static List<Map<String, dynamic>> _shareNodes(
    CoreShareLinkBatch batch, {
    int? inputIndex,
  }) {
    if (batch.issues.isNotEmpty) {
      throw CoreMethodException(
        code: 'share_link_conversion_failed',
        message: 'Input contains unsupported or invalid share links',
        details: {
          'input': ?inputIndex,
          'count': batch.issues.length,
          'issues': [
            for (final issue in batch.issues.take(32))
              {'code': issue.code, 'path': issue.path},
          ],
        },
      );
    }
    return batch.nodes;
  }

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

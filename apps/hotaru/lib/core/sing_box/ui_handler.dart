import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../models/models.dart';
import '../../common/common.dart';
import '../../enum/enum.dart';
import '../../l10n/l10n.dart';
import '../adapter.dart';
import '../geodata_store.dart';
import '../config/geodata.dart';
import '../config/application_settings.dart';
import '../config/clash_subscription.dart';
import '../config/profile.dart';
import '../config/provider_info.dart';
import '../config/route_preview.dart';
import 'application_profile.dart';
import '../logs.dart';
import '../routed_http.dart';
import 'routed_http.dart';
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
import '../connection_path.dart';
import '../maintenance.dart';
import '../event.dart';
import '../routing_mode.dart';
import '../profile_documents.dart';
import 'desktop_core.dart';
import 'config_preparation.dart';
import 'ui_routes.dart';
import 'ui_traffic.dart';
import 'http_probe.dart';
import 'service_diagnostics.dart';
import 'outbound_ip.dart';

final class SingBoxUiHandler extends CoreHandlerInterface
    implements
        CoreOutboundHttpClients,
        CoreRoutedHttp,
        CoreRoutingModes,
        CoreGlobalOutbound,
        CoreProfileTextBuilder,
        CoreProfileApplication,
        CoreRoutePreviewSource,
        CoreProcessTrafficSource,
        CoreGeoResources {
  final SingBoxDesktopCore core;
  final Future<void> Function()? afterClose;
  final CoreGeoDataStore Function()? geoData;
  late final void Function(CoreEvent) _publish;
  final _geoUpdates = <String, Future<void>>{};
  Future<void> _geoTail = Future.value();
  final Future<AcceptedSingBoxConfig?> Function(SetupParams, int?)?
  _prepareProfile;
  late final SingBoxUiRoutes _routes;
  late final SingBoxUiTraffic _traffic;
  late final SingBoxRoutedHttp _routedHttp;
  late final SingBoxHttpProbe _probe;
  late final SingBoxServiceDiagnostics _services;
  late final StreamSubscription<DesktopCoreFailure> _crashes;
  Future<CoreLifecycleResult>? _closing;
  int _profileRevision = 0;
  SingBoxApplicationProfilePreparer? _sourcePreparation;
  StreamSubscription<CoreLogMessage>? _logs;
  int _logRevision = 0;
  late final void Function(Log) _publishLog;

  SingBoxUiHandler(
    this.core, {
    void Function(CoreEvent)? onEvent,
    Duration Function()? trafficElapsed,
    this.afterClose,
    this.geoData,
    Future<AcceptedSingBoxConfig?> Function(SetupParams, int?)? prepareProfile,
  }) : _prepareProfile = prepareProfile {
    if (core.configuration == null) {
      throw ArgumentError('A prepared sing-box configuration is required');
    }
    final publish = onEvent ?? coreEventManager.sendEvent;
    _publish = publish;
    _publishLog = (log) =>
        publish(CoreEvent(type: CoreEventType.log, data: log.toJson()));
    _traffic = SingBoxUiTraffic(core: core, elapsed: trafficElapsed);
    _routedHttp = SingBoxRoutedHttp(core);
    _probe = SingBoxHttpProbe(
      transport: _routedHttp,
      observe: () {
        final source = core.adapter;
        if (source is! CoreTelemetry) {
          throw const CoreAdapterException('telemetry_unavailable');
        }
        return (source as CoreTelemetry).telemetry();
      },
    );
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
    _services = SingBoxServiceDiagnostics(
      send: (params, cancelled) => _routes.observeProbe(
        params,
        (request) => _probe.probe(request, cancelled: cancelled),
      ),
    );
    _crashes = core.lifecycle.crashEvents.listen(
      (failure) =>
          publish(CoreEvent(type: CoreEventType.crash, data: failure.code)),
    );
  }

  factory SingBoxUiHandler.withProfileFiles(
    SingBoxDesktopCore core, {
    required String configPath,
    required ClashSubscriptionImporter Function(CoreApplicationSettings)
    importer,
    required Future<CoreListenerSpec> Function(
      CoreProfileSpec,
      CoreApplicationSettings,
    )
    listeners,
    required Future<bool> Function(List<CoreConfigIssue>) review,
    ClashSubscriptionImporter Function(CoreApplicationSettings, Set<String>)?
    refreshImporter,
    void Function(CoreEvent)? onEvent,
    Map<String, String> providerFiles = const {},
    Future<Map<String, String>> Function()? providerFileGrants,
    Future<void> Function()? afterClose,
    CoreGeoDataStore Function()? geoData,
  }) {
    final preparation = SingBoxApplicationProfilePreparer(
      configPath: configPath,
      importer: importer,
      listeners: listeners,
      review: review,
      refreshImporter: refreshImporter,
      providerFiles: providerFiles,
      providerFileGrants: providerFileGrants,
    );
    return SingBoxUiHandler(
      core,
      prepareProfile: preparation.prepare,
      afterClose: afterClose,
      geoData: geoData,
      onEvent: onEvent,
    ).._sourcePreparation = preparation;
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
  Future<CoreLifecycleResult> close() {
    if (_closing == null) {
      _profileRevision++;
      _sourcePreparation?.close();
      _services.close();
      _closing = _close();
    }
    return _closing!;
  }

  @override
  Future<String> setupConfig(SetupParams setupParams) =>
      setupProfile(setupParams);

  @override
  Future<String> setupProfile(SetupParams params, {int? profileId}) async {
    if (_closing != null) throw const CoreAdapterException('closed');
    if (profileId != null && profileId < 0) {
      throw const CoreAdapterException('invalid_profile_identity');
    }
    final prepare = _prepareProfile;
    if (prepare == null) {
      throw const CoreAdapterException('profile_preparation_unavailable');
    }
    final revision = ++_profileRevision;
    final AcceptedSingBoxConfig? configuration;
    try {
      configuration = await prepare(params, profileId);
    } catch (_) {
      if (_closing != null) throw const CoreAdapterException('closed');
      if (revision != _profileRevision) {
        throw const CoreAdapterException('configuration_superseded');
      }
      rethrow;
    }
    if (_closing != null) throw const CoreAdapterException('closed');
    if (revision != _profileRevision) {
      throw const CoreAdapterException('configuration_superseded');
    }
    if (configuration == null) {
      throw const CoreAdapterException('configuration_review_cancelled');
    }
    if (configuration.profileId != profileId) {
      throw const CoreAdapterException('invalid_profile_identity');
    }
    final result = await _routes.applyConfiguration(configuration);
    if (revision != _profileRevision ||
        result.outcome == CoreLifecycleOutcome.superseded) {
      throw const CoreAdapterException('configuration_superseded');
    }
    return '';
  }

  @override
  Future<String> updateConfig(UpdateParams updateParams) async {
    if (_closing != null) throw const CoreAdapterException('closed');
    final preparation = _sourcePreparation;
    if (preparation == null) {
      throw const CoreAdapterException('application_settings_unavailable');
    }
    final revision = ++_profileRevision;
    preparation.cancelPending();
    return _finishMutation(
      _routes.updateConfiguration(
        (configuration, outbounds) =>
            preparation.update(configuration, outbounds, updateParams),
      ),
      revision,
    );
  }

  @override
  Set<String> get supportedTypes =>
      geoData == null ? const {} : const {'GEOIP', 'GEOSITE'};

  @override
  Future<String?> filePath(String type) async {
    final settings = core.configuration?.applicationData;
    final store = geoData?.call();
    return settings is CoreApplicationSettings && store != null
        ? store.path(type, settings.geoUrls)
        : null;
  }

  @override
  Future<String> updateGeoData(String type) async {
    final operation = refreshGeoData(type);
    unawaited(operation.catchError((Object _) {}));
    return '';
  }

  Future<void> refreshGeoData(String type) {
    if (_closing != null) throw const CoreAdapterException('closed');
    final key = type.toUpperCase();
    if (!supportedTypes.contains(key)) {
      throw const CoreAdapterException('unsupported_geo_resource');
    }
    final existing = _geoUpdates[key];
    if (existing != null) return existing;
    final operation = _geoTail.then((_) => _refreshGeoData(key));
    _geoUpdates[key] = operation;
    void release() {
      if (identical(_geoUpdates[key], operation)) _geoUpdates.remove(key);
    }

    _geoTail = operation.then<void>(
      (_) => release(),
      onError: (Object _, StackTrace _) => release(),
    );
    return operation;
  }

  Future<void> _refreshGeoData(String type) async {
    if (_closing != null) throw const CoreAdapterException('closed');
    final configuration = core.configuration;
    final settings = configuration?.applicationData;
    final preparation = _sourcePreparation;
    if (configuration == null ||
        settings is! CoreApplicationSettings ||
        preparation == null) {
      throw const CoreAdapterException('applied_profile_unavailable');
    }
    _publish(
      CoreEvent(
        type: CoreEventType.geoUpdate,
        data: {'type': type, 'updating': true},
      ),
    );
    String? failure;
    try {
      final kind = type == 'GEOIP' ? CoreGeoKind.ip : CoreGeoKind.site;
      final prefix = 'geo:${kind.name}:';
      final requests = [
        for (final set in configuration.profile.ruleSets)
          if (set.tag.startsWith(prefix))
            ?CoreGeoRequest.parse(kind, set.tag.substring(prefix.length)),
      ].where((request) => builtinCoreGeoMatch(request) == null).toList();
      await geoData!().update(type, urls: settings.geoUrls, requests: requests);
      if (_closing != null || !identical(core.configuration, configuration)) {
        throw const CoreAdapterException('configuration_superseded');
      }
      final revision = ++_profileRevision;
      preparation.cancelPending();
      await _finishMutation(
        _routes.updateConfiguration(
          (configuration, outbounds) =>
              preparation.refresh(configuration, outbounds, null),
          preserveMode: true,
        ),
        revision,
      );
    } catch (error) {
      failure = error is CoreAdapterException
          ? error.code
          : 'geo_update_failed';
      commonPrint.log(
        'geo update failed: $failure',
        logLevel: LogLevel.warning,
      );
      rethrow;
    } finally {
      if (_closing == null) {
        _publish(
          CoreEvent(
            type: CoreEventType.geoUpdate,
            data: {'type': type, 'updating': false, 'error': ?failure},
          ),
        );
      }
    }
  }

  @override
  Future<String> updateExternalProvider(String providerName) async {
    if (_closing != null) throw const CoreAdapterException('closed');
    final preparation = _sourcePreparation;
    if (preparation == null) {
      throw const CoreAdapterException('profile_preparation_unavailable');
    }
    final revision = ++_profileRevision;
    preparation.cancelPending();
    return _finishMutation(
      _routes.updateConfiguration(
        (configuration, outbounds) =>
            preparation.refresh(configuration, outbounds, providerName),
        preserveMode: true,
      ),
      revision,
    );
  }

  Future<String> _finishMutation(
    Future<CoreLifecycleResult> operation,
    int revision,
  ) async {
    final CoreLifecycleResult result;
    try {
      result = await operation;
    } catch (_) {
      if (_closing != null) throw const CoreAdapterException('closed');
      if (revision != _profileRevision) {
        throw const CoreAdapterException('configuration_superseded');
      }
      rethrow;
    }
    if (_closing != null) throw const CoreAdapterException('closed');
    if (revision != _profileRevision ||
        result.outcome == CoreLifecycleOutcome.superseded) {
      throw const CoreAdapterException('configuration_superseded');
    }
    return '';
  }

  Future<CoreLifecycleResult> _close() async {
    try {
      return await core.close();
    } finally {
      try {
        await stopLog();
      } finally {
        try {
          await _routedHttp.close();
          await _geoTail;
          await _routes.close();
          await _traffic.close();
          await _crashes.cancel();
        } finally {
          await afterClose?.call();
        }
      }
    }
  }

  @override
  Future<void> startLog() async {
    if (_closing != null) throw const CoreAdapterException('closed');
    if (_logs != null) return;
    final source = core.adapter;
    if (source is! CoreLogSource) {
      throw const CoreAdapterException('logs_unavailable');
    }
    final revision = ++_logRevision;
    _logs = (source as CoreLogSource).logs().listen(
      (entry) {
        if (_closing != null || revision != _logRevision) return;
        final level = switch (entry.level) {
          'trace' || 'debug' => LogLevel.debug,
          'warn' || 'warning' => LogLevel.warning,
          'error' || 'fatal' || 'panic' => LogLevel.error,
          _ => LogLevel.info,
        };
        _publishLog(Log.app(entry.payload).copyWith(logLevel: level));
      },
      onError: (Object _) {
        if (revision == _logRevision) _logs = null;
        commonPrint.log('sing-box log stream failed', logLevel: LogLevel.debug);
      },
      onDone: () {
        if (revision == _logRevision) _logs = null;
      },
      cancelOnError: true,
    );
  }

  @override
  Future<void> stopLog() async {
    _logRevision++;
    final stopping = _logs?.cancel();
    _logs = null;
    await stopping;
  }

  @override
  Future<CoreRoutePreview> previewRoute(String target) {
    final settings = core.configuration?.applicationData;
    if (settings is CoreApplicationSettings && settings.unconfigured) {
      throw const CoreAdapterException('applied_profile_unavailable');
    }
    return core.previewRoute(target);
  }

  @override
  Future<List<ServiceCheckItem>> serviceCheck(ServiceCheckParams params) =>
      _services.check(params);

  @override
  Future<RouteSnapshot> watchRoute(bool watch) => _routes.watch(watch);

  @override
  Future<RouteCheck?> checkRoutes(CheckRoutesParams params) =>
      _routes.check(params);

  @override
  Future<OutboundIpResult?> outboundIp(OutboundIpParams params) =>
      lookupSingBoxOutboundIp(
        params,
        (request, cancelled) => _routes.observeProbe(
          request,
          (request) => _probe.probe(request, cancelled: cancelled),
        ),
      );

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
    final nodes = configuration.profile.nodes;
    final groups = configuration.profile.selectors;
    final finalOutbound = configuration.profile.finalOutbound;
    final tag = await Isolate.run(
      () => CoreModeOutbounds.fromOutbounds(
        nodes,
        groups,
        finalOutbound,
      ).global.tag,
    );
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
  ) {
    _profileRevision++;
    return _routes.applyConfiguration(configuration);
  }

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
  Future<CoreProcessTraffic?> getProcessTraffic() async {
    final source = core.adapter;
    if (source is! CoreTelemetry) {
      throw const CoreAdapterException('telemetry_unavailable');
    }
    return (await (source as CoreTelemetry).telemetry()).processes;
  }

  @override
  Future<List<ExternalProvider>> getExternalProviders() async {
    final session = _session();
    final settings = core.configuration?.applicationData;
    if (settings is! CoreApplicationSettings) {
      throw const CoreAdapterException('application_settings_unavailable');
    }
    final entries = await Isolate.run(() {
      final byName = <String, ExternalProvider>{};
      for (final info in settings.providers) {
        byName[info.name] = ExternalProvider(
          name: info.name,
          type: info.kind == CoreProviderKind.proxy ? 'Proxy' : 'Rule',
          path: settings.providerFiles[info.path] ?? info.path,
          count: info.count,
          vehicleType: info.vehicle == CoreProviderVehicle.http
              ? 'HTTP'
              : 'File',
          updateAt: info.loadedAt,
        );
      }
      return byName.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    });
    _checkSession(session);
    return entries;
  }

  @override
  Future<ExternalProvider?> getExternalProvider(
    String externalProviderName,
  ) async => (await getExternalProviders())
      .where((entry) => entry.name == externalProviderName)
      .firstOrNull;

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
    final settings = configuration.applicationData;
    if (settings is CoreApplicationSettings && settings.unconfigured) {
      return const ProxiesData(all: [], proxies: {});
    }
    final nodes = await core.adapter.outbounds();
    if (!identical(configuration, core.configuration)) {
      throw const CoreAdapterException('session_changed');
    }
    final sourceNodes = configuration.profile.nodes;
    final sourceGroups = configuration.profile.selectors;
    final finalOutbound = configuration.profile.finalOutbound;
    final result = await Isolate.run(() {
      final modes = CoreModeOutbounds.fromOutbounds(
        sourceNodes,
        sourceGroups,
        finalOutbound,
      );
      final ownsGlobal =
          sourceNodes.any((node) => node.tag == 'GLOBAL') ||
          sourceGroups.any((group) => group.tag == 'GLOBAL');
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
  Future<ProbeResult> probe(ProbeParams params) => _probe.probe(params);

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
    final nodes = core.configuration?.profile.nodes ?? const <CoreNodeSpec>[];
    final sample = await (source is CoreConnectionPathTelemetry
        ? (source as CoreConnectionPathTelemetry).pathTelemetry()
        : (source as CoreTelemetry).telemetry());
    if (sample.activeTruncated) {
      throw const CoreAdapterException('connection_window_truncated');
    }
    final result = await Isolate.run(() {
      final paths = CoreConnectionPaths(sample, nodes);
      return [
        for (final entry in sample.active)
          for (final path in [paths.resolve(entry)])
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
              observedPath: path?.hops ?? const [],
              pathObservationStatus: path == null
                  ? ''
                  : path.complete
                  ? 'complete'
                  : 'partial',
              pathInbound: path == null ? '' : entry.inbound,
            ),
      ];
    });
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
  Future<T> withRoutedClient<T>(
    Future<T> Function(HttpClient client) action, {
    String? outbound,
    Duration timeout = const Duration(minutes: 2),
  }) => _routedHttp.withRoutedClient(
    action,
    outbound: outbound,
    timeout: timeout,
  );

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

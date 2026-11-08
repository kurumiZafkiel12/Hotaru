import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'core/config/application_settings.dart';
import 'core/config/clash_subscription.dart';
import 'core/config/dns.dart';
import 'core/config/geodata.dart';
import 'core/config/profile.dart';
import 'core/config/probe_listener.dart';
import 'core/config/provider_info.dart';
import 'core/desktop/model.dart';
import 'core/geodata_store.dart';
import 'core/refresh_scheduler.dart';
import 'core/controller.dart';
import 'core/event.dart';
import 'core/provider_cache.dart';
import 'core/provider_download.dart';
import 'core/provider_files.dart';
import 'core/sing_box/config_preparation.dart';
import 'core/sing_box/desktop_core.dart';
import 'core/sing_box/helper_desktop_core.dart';
import 'core/sing_box/ui_handler.dart';
import 'features/profile_traffic/recorder.dart';
import 'models/models.dart' show CoreEvent;

final class WindowsCoreApplication {
  final CoreController controller;
  final SingBoxDesktopCore core;

  const WindowsCoreApplication._(this.controller, this.core);

  static Future<WindowsCoreApplication> create({
    required String homeDirectory,
    required String configPath,
    required int mixedPort,
    required Future<Map<String, String>> Function() providerFiles,
    CoreGeoResolver? resolveGeo,
    required Future<bool> Function(List<CoreConfigIssue>) review,
    required Future<void> Function(ProfileTrafficObservation) persistTraffic,
    required void Function(Object, StackTrace) onError,
    void Function(CoreEvent)? onEvent,
    String? bundleDirectory,
    Future<SingBoxDesktopCore> Function(AcceptedSingBoxConfig)? createCore,
  }) async {
    final cache = await CoreProviderCache.open(
      p.join(homeDirectory, 'providers', 'sing-box'),
    );
    final projection = await CoreApplicationSettings.parse(
      jsonEncode({'mixed-port': mixedPort, 'ipv6': true}),
      skipCertVerify: false,
      unconfigured: true,
    );
    final settings = projection.settings;
    if (settings == null) {
      throw StateError('Invalid application listener settings');
    }
    final occupied = {mixedPort};
    final controllerPort = await _availablePort(occupied);
    occupied.add(controllerPort);
    final probePort = await _availablePort(occupied);
    final controllerSecret = _secret();
    final probeSecret = _secret();
    final initial = SingBoxConfigPreparer();
    final prepared = await initial.prepare(
      applicationData: settings,
      import: () async => CoreConfigImportResult(
        profile: CoreProfileSpec(
          nodes: const [
            CoreNodeSpec(tag: 'DIRECT', protocol: CoreNodeProtocol.direct),
          ],
          selectors: [],
          finalOutbound: 'DIRECT',
          dns: CoreDnsSpec(
            servers: const [
              CoreDnsServerSpec(tag: 'system', protocol: CoreDnsProtocol.local),
            ],
            finalServer: 'system',
            ipv6: true,
          ),
        ),
        issues: [],
      ),
      listeners: CoreListenerSpec(
        mixedPort: mixedPort,
        controllerPort: controllerPort,
        secret: controllerSecret,
        inboundsEnabled: false,
        probe: CoreProbeListenerSpec(port: probePort, secret: probeSecret),
      ),
    );
    final candidate = prepared.candidate;
    if (candidate == null) {
      throw StateError('Initial control-only configuration is invalid');
    }
    final accepted = initial.approve(candidate);
    final core =
        await (createCore?.call(accepted) ??
            createSingBoxHelperCore(
              configuration: accepted,
              bundleDirectory: bundleDirectory,
            ));
    ProfileTrafficRecorder? recorder;
    CoreRefreshScheduler? scheduler;
    late final CoreGeoDataStore geoData;
    late final SingBoxUiHandler handler;
    var attached = false;
    ClashSubscriptionImporter importer(
      CoreApplicationSettings settings,
      Set<String> force,
    ) {
      final source = core.configuration;
      final loader = () async {
        final bindings = await _providerBindings(settings.source, source);
        final access = await CoreProviderFileAccess.authorize(
          root: homeDirectory,
          files: settings.providerFiles,
        );
        return CoreCachedProviderLoader(
          cache: cache,
          downloader: CoreProviderDownloader(
            transport: handler,
            files: access,
            userAgent: settings.userAgent,
            outboundBindings: bindings,
          ),
        );
      }();
      return ClashSubscriptionImporter(
        resolve: (request) async => (await (await loader).loadProxy(
          request,
          force: force.contains(request.name),
        )).text,
        resolveRules: (request) async => (await (await loader).loadRule(
          request,
          force: force.contains(request.name),
        )).text,
        resolveGeo:
            resolveGeo ??
            (requests) => geoData.resolve(requests, urls: settings.geoUrls),
      );
    }

    try {
      handler = SingBoxUiHandler.withProfileFiles(
        core,
        configPath: configPath,
        importer: (settings) => importer(settings, const {}),
        refreshImporter: importer,
        providerFileGrants: providerFiles,
        listeners: (profile, settings) async {
          final previous =
              core.configuration?.listeners.dnsGroups?.ports ??
              const <String, int>{};
          final excluded = {
            controllerPort,
            probePort,
            settings.mixedPort,
            ?settings.inbound.httpPort,
            ?settings.inbound.socksPort,
            ?settings.dnsPort,
          };
          final groups = <String, int>{};
          for (final group
              in profile.dns?.groups ?? const <CoreDnsGroupSpec>[]) {
            final existing = previous[group.tag];
            final port = existing != null && !excluded.contains(existing)
                ? existing
                : await _availablePort(excluded);
            groups[group.tag] = port;
            excluded.add(port);
          }
          return CoreListenerSpec(
            mixedPort: settings.mixedPort,
            controllerPort: controllerPort,
            secret: controllerSecret,
            probe: CoreProbeListenerSpec(port: probePort, secret: probeSecret),
            inboundsEnabled: false,
            inbound: settings.inbound,
            tun: settings.tun,
            dnsPort: settings.dnsPort,
            dnsGroups: groups.isEmpty ? null : CoreDnsGroupListeners(groups),
          );
        },
        review: review,
        onEvent: onEvent ?? coreEventManager.sendEvent,
        geoData: () => geoData,
        afterClose: () async {
          try {
            await scheduler?.close();
          } finally {
            await recorder?.close();
          }
        },
      );
      attached = true;
      geoData = CoreGeoDataStore(home: homeDirectory, transport: handler);
      scheduler = CoreRefreshScheduler(
        onError: onError,
        entries: () async {
          final configuration = core.configuration;
          final settings = configuration?.applicationData;
          if (core.lifecycle.state is! DesktopCoreRunning ||
              settings is! CoreApplicationSettings ||
              settings.unconfigured) {
            return [];
          }
          final updates = <CoreScheduledRefresh>[
            for (final provider in settings.providers)
              if (provider.vehicle == CoreProviderVehicle.http &&
                  provider.interval > Duration.zero)
                CoreScheduledRefresh(
                  key: 'provider:${configuration!.profileId}:${provider.name}',
                  loadedAt: provider.loadedAt,
                  interval: provider.interval,
                  refresh: () async {
                    if (identical(configuration, core.configuration)) {
                      await handler.updateExternalProvider(provider.name);
                    }
                  },
                ),
          ];
          if (settings.geoAutoUpdate) {
            for (final type in ['GEOIP', 'GEOSITE']) {
              final file = File(await geoData.path(type, settings.geoUrls));
              final loadedAt = await file.exists()
                  ? await file.lastModified()
                  : DateTime.fromMillisecondsSinceEpoch(0);
              updates.add(
                CoreScheduledRefresh(
                  key: 'geo:${configuration!.profileId}:$type',
                  loadedAt: loadedAt,
                  interval: Duration(hours: settings.geoUpdateInterval),
                  refresh: () async {
                    if (identical(configuration, core.configuration)) {
                      await handler.refreshGeoData(type);
                    }
                  },
                ),
              );
            }
          }
          return updates;
        },
      );
      recorder = ProfileTrafficRecorder(
        core: core,
        persist: persistTraffic,
        onError: onError,
      );
      return WindowsCoreApplication._(CoreController.scoped(handler), core);
    } catch (_) {
      if (attached) {
        await handler.close();
      } else {
        await core.close();
        await recorder?.close();
      }
      rethrow;
    }
  }
}

String _secret() {
  final random = Random.secure();
  return base64UrlEncode(
    List.generate(32, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

Future<int> _availablePort(Set<int> excluded) async {
  for (var attempt = 0; attempt < 64; attempt++) {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    RawDatagramSocket? udp;
    try {
      if (excluded.contains(server.port)) continue;
      udp = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      return server.port;
    } on SocketException {
      continue;
    } finally {
      udp?.close();
      await server.close();
    }
  }
  throw StateError('No private loopback listener port is available');
}

Future<Map<String, String>> _providerBindings(
  String source,
  AcceptedSingBoxConfig? configuration,
) {
  final committed = configuration?.applicationData;
  final previous = committed is CoreApplicationSettings
      ? committed.source
      : null;
  final names = [
    ...?configuration?.profile.nodes.map((node) => node.tag),
    ...?configuration?.profile.selectors.map((group) => group.tag),
  ];
  return Isolate.run(
    () => previous == source
        ? {for (final name in names) name: name}
        : const <String, String>{},
  );
}

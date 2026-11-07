import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/ui_handler.dart';
import 'package:hotaru/enum/enum.dart' show CoreEventType;
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/probe_listener.dart';
import 'package:hotaru/core/outbound_http.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:drift/native.dart';
import 'package:hotaru/database/database.dart' as db;
import 'package:hotaru/features/profile_traffic/recorder.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/desktop/process_probe.dart';
import 'package:hotaru/core/sing_box/helper_desktop_core.dart';

import '../../plugins/code_forge/support.dart' show initEditorNative;
import 'support/dns_fixture.dart';
import 'loopback_proxy_fixture.dart' show freeLoopbackPort;

final _environment = Platform.environment;
final _enabled =
    Platform.isWindows &&
    _environment['CI'] == 'true' &&
    _environment['HOTARU_NATIVE_HELPER_BUNDLE'] != null;

Future<void> _expectSystem(int processId) async {
  final command =
      "\$ErrorActionPreference='Stop'; "
      "\$owner=Get-CimInstance Win32_Process -Filter 'ProcessId=$processId' | Invoke-CimMethod -MethodName GetOwnerSid; "
      "if (\$owner.ReturnValue -ne 0) { throw 'Cannot query process owner' }; \$owner.Sid";
  final process = await Process.start('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    command,
  ]);
  final output = utf8.decoder.bind(process.stdout).join();
  final errors = utf8.decoder.bind(process.stderr).join();
  var exited = false;
  try {
    final status = await process.exitCode.timeout(const Duration(seconds: 10));
    exited = true;
    expect(status, 0);
    expect((await output).trim(), 'S-1-5-18');
    expect((await errors).trim(), isEmpty);
  } finally {
    if (!exited) {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 2));
    }
  }
}

void main() {
  test(
    'real Flutter Rust IPC owns a SYSTEM Helper TUN session through restart and close',
    () async {
      await initEditorNative();
      final dnsServer = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(dnsServer.close);
      var dnsReceipts = 0;
      dnsServer.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = dnsServer.receive();
        if (packet == null) return;
        final expectedQuestion = question('helper-dns.invalid');
        expect(
          packet.data.sublist(12, expectedQuestion.length),
          expectedQuestion.sublist(12),
        );
        dnsReceipts++;
        dnsServer.send(answer(packet.data), packet.address, packet.port);
      });
      final providerServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => providerServer.close(force: true));
      var providerAvailable = true;
      var rulesAvailable = true;
      var rulesRequests = 0;
      var providerRequests = 0;
      providerServer.listen((request) async {
        if (request.uri.path == '/rules' || request.uri.path == '/ip-rules') {
          rulesRequests++;
          request.response.statusCode = rulesAvailable ? 200 : 503;
          request.response.write(
            request.uri.path == '/ip-rules'
                ? 'payload: [198.18.8.2/32]'
                : 'payload: [rule-fixture.invalid]',
          );
          await request.response.close();
          return;
        }
        providerRequests++;
        expect(
          request.headers.value('authorization'),
          'provider-fixture-token',
        );
        request.response.statusCode = providerAvailable ? 200 : 503;
        request.response.write(
          jsonEncode({
            'proxies': [
              {
                'name': 'proof',
                'type': 'http',
                'server': '127.0.0.1',
                'port': int.parse(_environment['HOTARU_NATIVE_PROXY_PORT']!),
              },
              {
                'name': 'rule-proof',
                'type': 'http',
                'server': '127.0.0.1',
                'port': int.parse(
                  _environment['HOTARU_NATIVE_RULE_PROXY_PORT']!,
                ),
              },
            ],
          }),
        );
        await request.response.close();
      });
      final providerClient = HttpClient()..findProxy = (_) => 'DIRECT';
      providerClient.connectionTimeout = const Duration(seconds: 10);
      addTearDown(() => providerClient.close(force: true));
      final importer = ClashSubscriptionImporter(
        resolveRules: (provider) async {
          expect(provider.outbound, 'DIRECT');
          final request = await providerClient.getUrl(provider.url!);
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          if (response.statusCode != 200) {
            await response.drain<void>();
            throw StateError('Rule provider fixture is unavailable');
          }
          return utf8.decoder
              .bind(response)
              .join()
              .timeout(const Duration(seconds: 10));
        },
        resolve: (provider) async {
          expect(provider.outbound, 'DIRECT');
          final request = await providerClient.getUrl(provider.url!);
          provider.headers.forEach((name, values) {
            for (final value in values) {
              request.headers.add(name, value);
            }
          });
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          if (response.statusCode != 200) {
            await response.drain<void>();
            throw StateError('Provider fixture is unavailable');
          }
          final bytes = <int>[];
          await for (final chunk in response.timeout(
            const Duration(seconds: 10),
          )) {
            if (bytes.length + chunk.length > provider.maxBytes) {
              throw StateError('Provider byte limit');
            }
            bytes.addAll(chunk);
          }
          return utf8.decode(bytes);
        },
      );
      final source = jsonEncode({
        'dns': {
          'enable': true,
          'nameserver': ['udp://127.0.0.1:${dnsServer.port}'],
          'use-hosts': false,
          'use-system-hosts': false,
        },
        'proxies': [
          {'name': 'direct', 'type': 'direct'},
        ],
        'proxy-providers': {
          'remote': {
            'type': 'http',
            'url': 'http://127.0.0.1:${providerServer.port}/proxies',
            'proxy': 'DIRECT',
            'interval': 1800,
            'header': {
              'Authorization': ['provider-fixture-token'],
            },
          },
        },
        'proxy-groups': [
          {
            'name': 'selected',
            'type': 'select',
            'proxies': ['direct'],
            'use': ['remote'],
          },
        ],
        'rule-providers': {
          'ip-path': {
            'type': 'http',
            'behavior': 'ipcidr',
            'url': 'http://127.0.0.1:${providerServer.port}/ip-rules',
            'proxy': 'DIRECT',
          },
          'domains': {
            'type': 'http',
            'behavior': 'domain',
            'url': 'http://127.0.0.1:${providerServer.port}/rules',
            'proxy': 'DIRECT',
          },
        },
        'rules': [
          'RULE-SET,ip-path,proof,no-resolve',
          'RULE-SET,domains,rule-proof',
          'MATCH,selected',
        ],
      });
      final imported = await importer.import(source);
      expect(imported.issues, isEmpty);
      final listeners = CoreListenerSpec(
        mixedPort: int.parse(_environment['HOTARU_NATIVE_MIXED_PORT']!),
        controllerPort: int.parse(_environment['HOTARU_NATIVE_API_PORT']!),
        secret: 'native-fixture-secret',
        probe: CoreProbeListenerSpec(
          port: await freeLoopbackPort(),
          secret: 'native-probe-fixture-12345678901234567890',
        ),
        tun: CoreTunSpec(
          interfaceName: _environment['HOTARU_NATIVE_TUN_NAME']!,
          addresses: ['198.18.8.1/30'],
          autoRoute: false,
          hijackDns: true,
        ),
      );
      final preparation = SingBoxConfigPreparer();
      final initial = await preparation.prepare(
        profileId: 1,
        import: () async => imported,
        listeners: listeners,
      );
      expect(initial.status, SingBoxPreparationStatus.ready);
      final accepted = preparation.approve(initial.candidate!);
      final service = await createSingBoxHelperCore(
        bundleDirectory: _environment['HOTARU_NATIVE_HELPER_BUNDLE']!,
        configuration: accepted,
      );
      final trafficDatabase = db.Database(NativeDatabase.memory());
      final uiEvents = <CoreEvent>[];
      final uiHandler = SingBoxUiHandler(service, onEvent: uiEvents.add);
      final controller = CoreController.scoped(uiHandler);
      await trafficDatabase.profilesDao.setAll([
        Profile.normal().copyWith(id: 1),
        Profile.normal().copyWith(id: 2),
      ]);
      final trafficErrors = <Object>[];
      final trafficRecorder = ProfileTrafficRecorder(
        core: service,
        persist: (sample) async {
          await trafficDatabase.profileTrafficDao.record(
            profileId: sample.profileId,
            sessionId: sample.sessionId,
            upload: sample.upload,
            download: sample.download,
          );
        },
        onError: (error, _) => trafficErrors.add(error),
      );
      final pids = <int>[];
      late CoreOutboundClients recoveredClients;
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      client.connectionTimeout = const Duration(seconds: 10);
      try {
        final starts = await Future.wait([service.start(), service.start()]);
        expect(starts.length, 2);
        expect(starts.map((result) => result.session!.pid).toSet().length, 1);
        final first = service.lifecycle.state as DesktopCoreRunning;
        expect(first.session.owner, CoreProcessOwner.helper);
        pids.add(first.session.pid);
        await _expectSystem(first.session.pid);
        final initialChoice = (await service.adapter.outbounds())
            .singleWhere((node) => node.name == 'selected')
            .selected;
        final initialRoute = await controller.watchRoute(true);
        final selection = await controller.changeProxy(
          const ChangeProxyParams(groupName: 'selected', proxyName: 'direct'),
        );
        expect(selection.changed, initialChoice != 'direct');
        expect(selection.coreEpoch, initialRoute!.coreEpoch);
        expect(await controller.routingMode(), CoreRoutingMode.rule);
        await controller.setRoutingMode(CoreRoutingMode.global);
        expect(await controller.routingMode(), CoreRoutingMode.global);
        await controller.setRoutingMode(CoreRoutingMode.rule);
        expect(await controller.routingMode(), CoreRoutingMode.rule);
        final changedRoutes = uiEvents
            .where((event) => event.type == CoreEventType.routeChanged)
            .map(
              (event) => RouteSnapshot.fromJson(
                Map<String, Object?>.from(event.data as Map),
              ),
            )
            .toList();
        expect(changedRoutes.length, greaterThanOrEqualTo(3));
        expect(
          changedRoutes.every(
            (snapshot) => snapshot.coreEpoch == initialRoute.coreEpoch,
          ),
          isTrue,
        );
        expect(
          changedRoutes.last.routeVersion,
          greaterThan(selection.routeVersion),
        );
        await controller.watchRoute(false);
        expect(
          (await service.adapter.outbounds())
              .singleWhere((node) => node.name == 'selected')
              .selected,
          'direct',
        );
        final literalPreview = await service.previewRoute('198.18.8.2');
        expect(literalPreview.status, CoreRoutePreviewStatus.resolved);
        expect(literalPreview.chain, ['proof']);
        final domainPreview = await service.previewRoute(
          'rule-fixture.invalid',
        );
        expect(domainPreview.status, CoreRoutePreviewStatus.resolved);
        expect(domainPreview.chain, ['rule-proof']);
        final finalPreview = await service.previewRoute(
          'offline-preview.invalid',
        );
        expect(finalPreview.status, CoreRoutePreviewStatus.resolved);
        expect(finalPreview.chain, ['selected', 'direct']);
        expect((await service.adapter.connections()).entries, isEmpty);
        expect(dnsReceipts, 0);
        expect(providerRequests, 1);
        expect(rulesRequests, 2);
        final request = await client.getUrl(Uri.parse('http://198.18.8.2/'));
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        expect(response.statusCode, 200);
        expect(
          await utf8.decoder
              .bind(response)
              .join()
              .timeout(const Duration(seconds: 10)),
          'helper-tun-proof',
        );

        await service.adapter.selectOutbound('selected', 'proof');
        final dnsResponse = await udpQuery(
          53,
          question('helper-dns.invalid'),
          address: InternetAddress('198.18.8.2'),
        );
        expect(dnsResponse.sublist(dnsResponse.length - 4), [192, 0, 2, 45]);
        expect(dnsReceipts, 1);

        final ruleClient = HttpClient()
          ..findProxy = (_) =>
              'PROXY 127.0.0.1:${_environment['HOTARU_NATIVE_MIXED_PORT']}';
        try {
          final ruleRequest = await ruleClient.getUrl(
            Uri.parse('http://rule-fixture.invalid/'),
          );
          final ruleResponse = await ruleRequest.close().timeout(
            const Duration(seconds: 10),
          );
          expect(
            await utf8.decoder
                .bind(ruleResponse)
                .join()
                .timeout(const Duration(seconds: 10)),
            'helper-tun-proof',
          );
          expect(rulesRequests, 2);
          expect(dnsReceipts, 1);
        } finally {
          ruleClient.close(force: true);
        }

        final invalid = await preparation.prepare(
          import: () async => CoreConfigImportResult(
            profile: CoreProfileSpec(
              nodes: const [
                CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
              ],
              selectors: [],
              finalOutbound: 'missing',
            ),
            issues: const [],
          ),
          listeners: listeners,
        );
        expect(invalid.status, SingBoxPreparationStatus.invalid);
        final hugeTag = 'n' * 32768;
        final oversized = await preparation.prepare(
          import: () async => CoreConfigImportResult(
            profile: CoreProfileSpec(
              nodes: [
                CoreNodeSpec(tag: hugeTag, protocol: CoreNodeProtocol.direct),
              ],
              selectors: [],
              finalOutbound: hugeTag,
              dns: imported.profile!.dns,
              rules: List.generate(
                600,
                (index) => CoreRouteRule(
                  kind: CoreRuleKind.domain,
                  value: 'r$index.invalid',
                  outbound: hugeTag,
                ),
              ),
            ),
            issues: const [],
          ),
          listeners: listeners,
        );
        expect(oversized.status, SingBoxPreparationStatus.invalid);
        expect(
          oversized.issues.map((issue) => issue.code),
          contains('compiled_config_too_large'),
        );
        final review = await preparation.prepare(
          import: () => ClashProfileImporter().import(
            'mixed-port: 12345\nrules: ["MATCH,DIRECT"]',
          ),
          listeners: CoreListenerSpec(
            mixedPort: listeners.mixedPort,
            controllerPort: listeners.controllerPort,
            secret: listeners.secret,
          ),
        );
        expect(review.status, SingBoxPreparationStatus.ready);
        expect(
          review.candidate!.warnings.single.code,
          'app_owned_setting_replaced',
        );
        expect(() => preparation.approve(review.candidate!), throwsStateError);
        expect(
          (service.lifecycle.state as DesktopCoreRunning).session.pid,
          first.session.pid,
        );
        expect(
          (await service.adapter.outbounds()).any(
            (node) => node.name == 'rule-proof',
          ),
          isTrue,
        );

        providerAvailable = false;
        final failedRefresh = await importer.import(source);
        expect(failedRefresh.profile, isNull);
        expect(
          failedRefresh.issues.map((issue) => issue.code),
          contains('provider_resolution_failed'),
        );
        expect(
          (service.lifecycle.state as DesktopCoreRunning).session.pid,
          first.session.pid,
        );
        expect(
          (await service.adapter.outbounds()).any(
            (node) => node.name == 'proof',
          ),
          isTrue,
        );
        expect(providerRequests, 2);
        providerAvailable = true;
        rulesAvailable = false;
        final failedRules = await importer.import(source);
        expect(failedRules.profile, isNull);
        expect(
          failedRules.issues.map((issue) => issue.code),
          contains('rule_provider_resolution_failed'),
        );
        expect(
          (service.lifecycle.state as DesktopCoreRunning).session.pid,
          first.session.pid,
        );
        expect(
          (await service.adapter.outbounds()).any(
            (node) => node.name == 'rule-proof',
          ),
          isTrue,
        );
        expect(rulesRequests, greaterThanOrEqualTo(3));

        final replacementResult = await preparation.prepare(
          profileId: 2,
          import: () async => imported,
          listeners: CoreListenerSpec(
            mixedPort: listeners.mixedPort,
            controllerPort: listeners.controllerPort,
            secret: 'replacement-fixture-secret',
            probe: CoreProbeListenerSpec(
              port: listeners.probe!.port,
              secret: 'replacement-probe-fixture-12345678901234567890',
            ),
            tun: listeners.tun,
          ),
        );
        final replacement = preparation.approve(replacementResult.candidate!);
        final applied = await service.applyConfiguration(replacement);
        final replacedSession = applied.session!;
        pids.add(replacedSession.pid);
        expect(await isProcessAlive(first.session.pid), isFalse);
        expect(service.configuration, same(replacement));
        expect(
          (await service.adapter.outbounds()).any(
            (node) => node.name == 'proof',
          ),
          isTrue,
        );
        await _expectSystem(replacedSession.pid);

        final occupied = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        try {
          final rejectedResult = await preparation.prepare(
            import: () async => imported,
            listeners: CoreListenerSpec(
              mixedPort: occupied.port,
              controllerPort: listeners.controllerPort,
              secret: 'rejected-fixture-secret',
              tun: listeners.tun,
            ),
          );
          expect(rejectedResult.status, SingBoxPreparationStatus.ready);
          final rejected = preparation.approve(rejectedResult.candidate!);
          await expectLater(
            service.applyConfiguration(rejected),
            throwsA(
              isA<DesktopCoreFailure>().having(
                (failure) => failure.code,
                'code',
                'configuration_rejected_previous_restored',
              ),
            ),
          );
        } finally {
          await occupied.close();
        }
        final restored =
            (service.lifecycle.state as DesktopCoreRunning).session;
        pids.add(restored.pid);
        expect(await isProcessAlive(replacedSession.pid), isFalse);
        expect(service.configuration, same(replacement));
        await _expectSystem(restored.pid);
        await service.adapter.selectOutbound('selected', 'direct');
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var restoredRequests = 0;
        origin.listen((request) async {
          expect(request.uri.path, '/restored');
          restoredRequests++;
          request.response.write('restored-configuration-proof');
          await request.response.close();
        });
        final recoveredPreview = await service.previewRoute(
          'offline-preview.invalid',
        );
        expect(recoveredPreview.status, CoreRoutePreviewStatus.resolved);
        expect(recoveredPreview.chain, ['selected', 'direct']);
        final recoveredRoute = await controller.watchRoute(true);
        expect(recoveredRoute!.coreEpoch, greaterThan(initialRoute.coreEpoch));
        await controller.watchRoute(false);
        final restoredClient = HttpClient()
          ..findProxy = (_) => 'PROXY 127.0.0.1:${listeners.mixedPort}';
        try {
          final request = await restoredClient.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/restored'),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          expect(
            await utf8.decoder.bind(response).join(),
            'restored-configuration-proof',
          );
          expect(restoredRequests, 1);
          final probePayloads =
              await (service.adapter as CoreOutboundHttpClients)
                  .withOutboundClients('selected', (clients) async {
                    recoveredClients = clients;
                    expect(clients.chain, ['selected', 'direct']);
                    final payloads = <String>[];
                    for (var index = 0; index < 2; index++) {
                      final probeClient = clients.createClient();
                      final probeRequest = await probeClient.getUrl(
                        Uri.parse('http://127.0.0.1:${origin.port}/restored'),
                      );
                      final probeResponse = await probeRequest.close();
                      expect(probeResponse.statusCode, 200);
                      payloads.add(
                        await utf8.decoder.bind(probeResponse).join(),
                      );
                      probeClient.close(force: true);
                    }
                    return payloads;
                  });
          expect(probePayloads, List.filled(2, 'restored-configuration-proof'));
          expect(restoredRequests, 3);
          CoreTelemetrySnapshot? observed;
          for (var attempt = 0; attempt < 100; attempt++) {
            observed = await (service.adapter as CoreTelemetry).telemetry();
            if (observed.closed.any(
              (entry) => entry.inbound == 'hotaru-probe',
            )) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(
            observed!.closed.any(
              (entry) =>
                  entry.inbound == 'hotaru-probe' &&
                  entry.outbound == 'direct' &&
                  entry.closedAt != null &&
                  entry.download > 0,
            ),
            isTrue,
          );
          expect(observed.downloadTotal, greaterThan(0));
        } finally {
          restoredClient.close(force: true);
          await origin.close(force: true);
        }

        await service.restart();
        expect(
          recoveredClients.createClient,
          throwsA(
            isA<CoreAdapterException>().having(
              (error) => error.code,
              'code',
              'session_changed',
            ),
          ),
        );
        final second = service.lifecycle.state as DesktopCoreRunning;
        pids.add(second.session.pid);
        expect(second.session.sessionId, isNot(first.session.sessionId));
        expect(second.session.pid, isNot(first.session.pid));
        expect(await isProcessAlive(first.session.pid), isFalse);
        expect(
          (await service.adapter.outbounds()).any(
            (node) => node.name == 'proof',
          ),
          isTrue,
        );

        await service.stop();
        expect(service.lifecycle.state, isA<DesktopCoreIdle>());
        expect(await isProcessAlive(second.session.pid), isFalse);
        await service.start();
        final third = service.lifecycle.state as DesktopCoreRunning;
        pids.add(third.session.pid);
        await service.close();
        await service.close();
        expect(service.lifecycle.state, isA<DesktopCoreClosed>());
        expect(await isProcessAlive(third.session.pid), isFalse);
        await trafficRecorder.flush();
        final finalSources = [
          first.session,
          replacedSession,
          restored,
          second.session,
          third.session,
        ];
        final finalTotals = await Future.wait([
          for (final session in finalSources)
            (session.lease as CoreFinalTrafficSource).finalTraffic.timeout(
              const Duration(seconds: 2),
            ),
        ]);
        expect(finalTotals.every((totals) => totals != null), isTrue);
        final firstTraffic = await trafficDatabase.profileTrafficDao
            .query(1)
            .getSingle();
        final secondTraffic = await trafficDatabase.profileTrafficDao
            .query(2)
            .getSingle();
        expect(firstTraffic.upload, finalTotals.first!.upload);
        expect(firstTraffic.download, finalTotals.first!.download);
        expect(firstTraffic.download, greaterThan(0));
        expect(
          secondTraffic.upload,
          finalTotals.skip(1).fold(0, (sum, totals) => sum + totals!.upload),
        );
        expect(
          secondTraffic.download,
          finalTotals.skip(1).fold(0, (sum, totals) => sum + totals!.download),
        );
        expect(secondTraffic.download, greaterThan(0));
        expect(
          await trafficDatabase.profileTrafficSessions.count.getSingle(),
          5,
        );
        expect(trafficErrors, isEmpty);
        final badBundle = await Directory.systemTemp.createTemp(
          'hotaru_bad_digest_',
        );
        try {
          final manifest =
              jsonDecode(
                    await File(
                      '${_environment['HOTARU_NATIVE_HELPER_BUNDLE']!}/manifest.json',
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
          manifest['coreSha256'] = '0' * 64;
          await File(
            '${badBundle.path}/manifest.json',
          ).writeAsString(jsonEncode(manifest));
          final deniedPreparer = SingBoxConfigPreparer();
          final deniedConfig = await deniedPreparer.prepare(
            import: () async => CoreConfigImportResult(
              profile: CoreProfileSpec(
                nodes: const [
                  CoreNodeSpec(
                    tag: 'direct',
                    protocol: CoreNodeProtocol.direct,
                  ),
                ],
                selectors: [],
                finalOutbound: 'direct',
              ),
              issues: const [],
            ),
            listeners: CoreListenerSpec(
              mixedPort: int.parse(_environment['HOTARU_NATIVE_MIXED_PORT']!),
              controllerPort: int.parse(
                _environment['HOTARU_NATIVE_API_PORT']!,
              ),
              secret: 'denied-fixture-secret',
            ),
          );
          final denied = await createSingBoxHelperCore(
            bundleDirectory: badBundle.path,
            configuration: deniedPreparer.approve(deniedConfig.candidate!),
          );
          try {
            await expectLater(
              denied.start(),
              throwsA(isA<DesktopCoreFailure>()),
            );
            expect(
              (denied.lifecycle.state as DesktopCoreFailed).failure.pid,
              isNull,
            );
          } finally {
            await denied.close();
          }
        } finally {
          await badBundle.delete(recursive: true);
        }
        await File(_environment['HOTARU_NATIVE_HELPER_RESULT']!).writeAsString(
          jsonEncode({
            'native_ipc': true,
            'configuration_preflight': true,
            'configuration_replacement': true,
            'route_preview_committed_ir': true,
            'route_preview_no_dial': true,
            'route_preview_recovered_configuration': true,
            'node_http_recovered_configuration': true,
            'node_http_factory_recovered_configuration': true,
            'ui_controller_selection_and_modes': true,
            'ui_route_epoch_recovered': true,
            'native_closed_telemetry': true,
            'profile_traffic_final_persisted': true,
            'failed_activation_restored': true,
            'restored_configuration_payload': true,
            'oversized_config_keeps_session': true,
            'unacknowledged_warning_keeps_session': true,
            'provider_import': true,
            'rule_provider_import': true,
            'ip_rule_provider_import': true,
            'ip_no_resolve_literal_receipt': true,
            'ip_no_resolve_domain_skipped_dns': true,
            'failed_rule_provider_keeps_session': true,
            'failed_provider_keeps_session': true,
            'helper_system': true,
            'tun_payload': true,
            'tun_dns_receipt': true,
            'restart': true,
            'terminal_close': true,
            'digest_mismatch_refused': true,
            'pids': pids,
          }),
        );
      } finally {
        client.close(force: true);
        await service.close();
        await uiHandler.close();
        await trafficRecorder.close();
        await trafficDatabase.close();
      }
    },
    skip: _enabled ? false : 'Opt-in disposable Windows SCM integration only',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

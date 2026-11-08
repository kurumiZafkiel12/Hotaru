import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/ui_handler.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/dns.dart';
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
import 'package:hotaru/core/config/application_settings.dart';
import 'package:hotaru/core/provider_cache.dart';
import 'package:hotaru/core/provider_download.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/sing_box/helper_desktop_core.dart';

import '../../plugins/code_forge/support.dart' show initEditorNative;
import 'support/dns_fixture.dart';
import 'support/windows_process_witness.dart';
import 'loopback_proxy_fixture.dart'
    show freeLoopbackPort, LoopbackProxyFixture;

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
      final processes = <int, WindowsProcessWitness>{};
      void recordProcess(int pid) {
        processes[pid] = WindowsProcessWitness.open(pid);
        pids.add(pid);
      }

      addTearDown(() {
        for (final process in processes.values) {
          process.close();
        }
      });
      late CoreOutboundClients recoveredClients;
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      client.connectionTimeout = const Duration(seconds: 10);
      try {
        final starts = await Future.wait([service.start(), service.start()]);
        expect(starts.length, 2);
        expect(starts.map((result) => result.session!.pid).toSet().length, 1);
        final first = service.lifecycle.state as DesktopCoreRunning;
        expect(first.session.owner, CoreProcessOwner.helper);
        recordProcess(first.session.pid);
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
        final initialUiTraffic = await controller.getTotalTraffic(false);
        await controller.getTraffic(false);
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

        final receivedUiTraffic = await controller.getTotalTraffic(false);
        expect(receivedUiTraffic.down, greaterThan(initialUiTraffic.down));
        expect((await controller.getTraffic(false)).speed, greaterThan(0));
        final rawBeforeUiReset = await (service.adapter as CoreTelemetry)
            .telemetry();
        await uiHandler.resetTraffic();
        final resetUiTraffic = await controller.getTotalTraffic(false);
        final rawAfterUiReset = await (service.adapter as CoreTelemetry)
            .telemetry();
        expect(resetUiTraffic.up, greaterThanOrEqualTo(0));
        expect(resetUiTraffic.down, greaterThanOrEqualTo(0));
        expect(
          resetUiTraffic.up,
          lessThanOrEqualTo(rawAfterUiReset.uploadTotal),
        );
        expect(resetUiTraffic.down, lessThan(rawAfterUiReset.downloadTotal));
        expect(
          rawAfterUiReset.uploadTotal,
          greaterThanOrEqualTo(rawBeforeUiReset.uploadTotal),
        );
        expect(
          rawAfterUiReset.downloadTotal,
          greaterThanOrEqualTo(rawBeforeUiReset.downloadTotal),
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
        recordProcess(replacedSession.pid);
        expect(processes[first.session.pid]!.hasExited, isTrue);
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
        recordProcess(restored.pid);
        expect(processes[replacedSession.pid]!.hasExited, isTrue);
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
          expect(
            (await controller.getTotalTraffic(false)).down,
            greaterThan(0),
          );
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
        recordProcess(second.session.pid);
        expect(second.session.sessionId, isNot(first.session.sessionId));
        expect(second.session.pid, isNot(first.session.pid));
        expect(processes[first.session.pid]!.hasExited, isTrue);
        expect(
          (await service.adapter.outbounds()).any(
            (node) => node.name == 'proof',
          ),
          isTrue,
        );

        await service.stop();
        expect(service.lifecycle.state, isA<DesktopCoreIdle>());
        expect(processes[second.session.pid]!.hasExited, isTrue);
        await service.start();
        final third = service.lifecycle.state as DesktopCoreRunning;
        recordProcess(third.session.pid);
        await service.close();
        await service.close();
        expect(service.lifecycle.state, isA<DesktopCoreClosed>());
        expect(processes[third.session.pid]!.hasExited, isTrue);
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
            'ui_traffic_rate_and_local_reset': true,
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

  test(
    'real SYSTEM Helper retains control without listeners or a TUN in idle mode',
    () async {
      await initEditorNative();
      final mixed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final dns = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var connections = 0;
      for (final socket in [mixed, probe, dns]) {
        addTearDown(socket.close);
        socket.listen((client) {
          connections++;
          client.destroy();
        });
      }
      final listeners = CoreListenerSpec(
        mixedPort: mixed.port,
        controllerPort: await freeLoopbackPort(),
        secret: 'control-only-native-fixture',
        inboundsEnabled: false,
        probe: CoreProbeListenerSpec(
          port: probe.port,
          secret: 'idle-native-probe-1234567890123456789012345',
        ),
        dnsPort: dns.port,
        tun: CoreTunSpec(
          interfaceName: _environment['HOTARU_NATIVE_TUN_NAME']!,
          addresses: ['198.18.8.1/30'],
          autoRoute: false,
          hijackDns: true,
        ),
      );
      final profile = CoreProfileSpec(
        nodes: const [
          CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
        ],
        selectors: [
          CoreSelectorSpec(tag: 'selected', members: ['direct']),
        ],
        finalOutbound: 'selected',
        dns: CoreDnsSpec(
          servers: const [
            CoreDnsServerSpec(tag: 'local', protocol: CoreDnsProtocol.local),
          ],
          finalServer: 'local',
        ),
      );
      final preparer = SingBoxConfigPreparer();
      final result = await preparer.prepare(
        import: () async =>
            CoreConfigImportResult(profile: profile, issues: []),
        listeners: listeners,
      );
      expect(result.status, SingBoxPreparationStatus.ready);
      final accepted = preparer.approve(result.candidate!);
      expect(
        jsonDecode(utf8.decode(accepted.bootstrap.bytes))['config']['inbounds'],
        isEmpty,
      );
      final core = await createSingBoxHelperCore(
        bundleDirectory: _environment['HOTARU_NATIVE_HELPER_BUNDLE']!,
        configuration: accepted,
      );
      late int pid;
      WindowsProcessWitness? process;
      try {
        final started = await core.start();
        pid = started.session!.pid;
        process = WindowsProcessWitness.open(pid);
        addTearDown(process.close);
        expect(started.session!.owner, CoreProcessOwner.helper);
        await _expectSystem(pid);
        await core.adapter.selectOutbound('selected', 'direct');
        expect(
          (await core.adapter.outbounds())
              .singleWhere((entry) => entry.name == 'selected')
              .selected,
          'direct',
        );
        var called = false;
        await expectLater(
          (core.adapter as CoreOutboundHttpClients).withOutboundClient(
            'direct',
            (_) async {
              called = true;
            },
          ),
          throwsA(
            isA<CoreAdapterException>().having(
              (error) => error.code,
              'code',
              'outbound_http_unavailable',
            ),
          ),
        );
        expect(called, isFalse);
        expect(connections, 0);
        final interfaces = await NetworkInterface.list(includeLoopback: true);
        expect(
          interfaces
              .expand((entry) => entry.addresses)
              .any((address) => address.address == '198.18.8.1'),
          isFalse,
        );
        expect(core.lifecycle.state, isA<DesktopCoreRunning>());
      } finally {
        await core.close();
      }
      expect(process.hasExited, isTrue);
      final path = File(_environment['HOTARU_NATIVE_HELPER_RESULT']!);
      final report = await path.exists()
          ? Map<String, dynamic>.from(
              jsonDecode(await path.readAsString()) as Map,
            )
          : <String, dynamic>{};
      report['control_only_helper'] = true;
      (report.putIfAbsent('pids', () => <int>[]) as List).add(pid);
      await path.writeAsString(jsonEncode(report));
    },
    skip: _enabled ? false : 'Opt-in disposable Windows SCM integration only',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'real SYSTEM Helper UI pause resume and restart retain policy across TUN sessions',
    () async {
      await initEditorNative();
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      var requests = 0;
      origin.listen((request) async {
        requests++;
        request.response.write('ui-listener-proof');
        await request.response.close();
      });
      final listeners = CoreListenerSpec(
        mixedPort: await freeLoopbackPort(),
        controllerPort: await freeLoopbackPort(),
        secret: 'ui-listener-native-fixture',
        probe: CoreProbeListenerSpec(
          port: await freeLoopbackPort(),
          secret: 'ui-listener-probe-1234567890123456789012345',
        ),
        tun: CoreTunSpec(
          interfaceName: _environment['HOTARU_NATIVE_TUN_NAME']!,
          addresses: ['198.18.9.1/30'],
          autoRoute: false,
        ),
      );
      final preparer = SingBoxConfigPreparer();
      final prepared = await preparer.prepare(
        import: () async => CoreConfigImportResult(
          profile: CoreProfileSpec(
            nodes: const [
              CoreNodeSpec(tag: 'A', protocol: CoreNodeProtocol.direct),
              CoreNodeSpec(tag: 'B', protocol: CoreNodeProtocol.direct),
            ],
            selectors: [
              CoreSelectorSpec(
                tag: 'selected',
                members: ['A', 'B'],
                selected: 'A',
              ),
            ],
            finalOutbound: 'selected',
          ),
          issues: [],
        ),
        listeners: listeners,
      );
      expect(prepared.status, SingBoxPreparationStatus.ready);
      final core = await createSingBoxHelperCore(
        bundleDirectory: _environment['HOTARU_NATIVE_HELPER_BUNDLE']!,
        configuration: preparer.approve(prepared.candidate!),
      );
      final handler = SingBoxUiHandler(core, onEvent: (_) {});
      final controller = CoreController.scoped(handler);
      final processes = <WindowsProcessWitness>[];
      final pids = <int>[];
      addTearDown(() {
        for (final process in processes) {
          process.close();
        }
      });
      Future<void> record() async {
        final running = core.lifecycle.state as DesktopCoreRunning;
        pids.add(running.session.pid);
        processes.add(WindowsProcessWitness.open(running.session.pid));
        await _expectSystem(running.session.pid);
      }

      Future<void> policy() async {
        expect(await controller.routingMode(), CoreRoutingMode.global);
        final groups = await core.adapter.outbounds();
        expect(
          groups.singleWhere((entry) => entry.name == 'selected').selected,
          'B',
        );
        expect(
          groups.singleWhere((entry) => entry.name == 'Hotaru GLOBAL').selected,
          'B',
        );
      }

      Future<void> payload() async {
        final client = HttpClient()
          ..findProxy = (_) => 'PROXY 127.0.0.1:${listeners.mixedPort}';
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/ui-listener'),
          );
          final response = await request.close();
          expect(
            await response.transform(utf8.decoder).join(),
            'ui-listener-proof',
          );
        } finally {
          client.close(force: true);
        }
      }

      try {
        await controller.start();
        await record();
        await controller.changeProxy(
          const ChangeProxyParams(groupName: 'selected', proxyName: 'B'),
        );
        await controller.changeProxy(
          const ChangeProxyParams(groupName: 'Hotaru GLOBAL', proxyName: 'B'),
        );
        await controller.setRoutingMode(CoreRoutingMode.global);
        final memory = await controller.getMemoryStats();
        expect(memory, isNotNull);
        expect(memory!.rss, greaterThan(0));
        expect(memory.heapInuse, greaterThan(0));
        await payload();
        final beforeMaintenance = await controller.getTotalTraffic(false);
        final maintenanceSession =
            (core.lifecycle.state as DesktopCoreRunning).session.sessionId;
        await controller.requestGc();
        await controller.resetConnections();
        expect(await controller.clearDnsCache(), isTrue);
        final afterMaintenance = await controller.getTotalTraffic(false);
        expect(afterMaintenance.up, greaterThanOrEqualTo(beforeMaintenance.up));
        expect(
          afterMaintenance.down,
          greaterThanOrEqualTo(beforeMaintenance.down),
        );
        expect(
          (core.lifecycle.state as DesktopCoreRunning).session.sessionId,
          maintenanceSession,
        );
        await policy();
        expect(await controller.stopListener(), isTrue);
        expect(processes.last.hasExited, isTrue);
        await record();
        await policy();
        expect(core.configuration!.listeners.inboundsEnabled, isFalse);
        final interfaces = await NetworkInterface.list(includeLoopback: true);
        expect(
          interfaces
              .expand((entry) => entry.addresses)
              .any((address) => address.address == '198.18.9.1'),
          isFalse,
        );
        var called = false;
        await expectLater(
          controller.withOutboundClients('B', (client) async {
            called = true;
          }),
          throwsA(isA<CoreAdapterException>()),
        );
        expect(called, isFalse);
        expect(await controller.startListener(), isTrue);
        expect(processes.last.hasExited, isTrue);
        await record();
        await policy();
        await payload();
        await controller.restart();
        expect(processes.last.hasExited, isTrue);
        await record();
        await policy();
        await payload();
        expect(requests, 3);
      } finally {
        await controller.close();
      }
      expect(processes.every((process) => process.hasExited), isTrue);
      final path = File(_environment['HOTARU_NATIVE_HELPER_RESULT']!);
      final report = await path.exists()
          ? Map<String, dynamic>.from(
              jsonDecode(await path.readAsString()) as Map,
            )
          : <String, dynamic>{};
      report['ui_listener_policy_retained'] = true;
      report['ui_native_memory'] = true;
      report['ui_runtime_maintenance'] = true;
      (report.putIfAbsent('pids', () => <int>[]) as List).addAll(pids);
      await path.writeAsString(jsonEncode(report));
    },
    skip: _enabled ? false : 'Opt-in disposable Windows SCM integration only',
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'real SYSTEM Helper applies reviewed application files and preserves the active source after cancellation',
    () async {
      await initEditorNative();
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-native-app-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      final proxyA = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        origin.port,
      );
      addTearDown(proxyA.close);
      final proxyB = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        origin.port,
      );
      addTearDown(proxyB.close);
      var receipts = 0;
      origin.listen((request) async {
        receipts++;
        request.response.write('application-source-receipt');
        await request.response.close();
      });
      final sourceServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => sourceServer.close(force: true));
      var sourceReads = 0;
      final providerBody = jsonEncode({
        'proxies': [
          for (final (name, proxyPort) in [
            ('A', proxyA.server.port),
            ('B', proxyB.server.port),
          ])
            {
              'name': name,
              'type': 'http',
              'server': '127.0.0.1',
              'port': proxyPort,
            },
        ],
      });
      sourceServer.listen((request) async {
        sourceReads++;
        request.response.headers.set('etag', 'source-v1');
        if (request.headers.value(HttpHeaders.ifNoneMatchHeader) ==
            'source-v1') {
          request.response.statusCode = HttpStatus.notModified;
        } else {
          request.response.write(providerBody);
        }
        await request.response.close();
      });
      final providerCache = await CoreProviderCache.open(
        '${directory.path}/provider-cache',
      );
      final occupied = <int>{};
      Future<int> port() async {
        while (true) {
          final candidate = await freeLoopbackPort();
          if (occupied.add(candidate)) return candidate;
        }
      }

      final listeners = CoreListenerSpec(
        mixedPort: await port(),
        controllerPort: await port(),
        secret: 'application-private-fixture',
        inboundsEnabled: false,
        probe: CoreProbeListenerSpec(
          port: await port(),
          secret: 'application-probe-fixture-1234567890123456',
        ),
      );
      final initial = SingBoxConfigPreparer();
      final prepared = await initial.prepare(
        import: () async => CoreConfigImportResult(
          profile: CoreProfileSpec(
            nodes: const [
              CoreNodeSpec(tag: 'DIRECT', protocol: CoreNodeProtocol.direct),
            ],
            selectors: [],
            finalOutbound: 'DIRECT',
          ),
          issues: [],
        ),
        listeners: listeners,
      );
      expect(prepared.status, SingBoxPreparationStatus.ready);
      final core = await createSingBoxHelperCore(
        bundleDirectory: _environment['HOTARU_NATIVE_HELPER_BUNDLE']!,
        configuration: initial.approve(prepared.candidate!),
      );
      addTearDown(core.close);
      final file = await File('${directory.path}/application.yaml')
          .writeAsString(
            jsonEncode({
              'find-process-mode': 'always',
              'mixed-port': listeners.mixedPort,
              'ipv6': true,
              'mode': 'rule',
              'authentication': ['fixture:password:part'],
              'secret': 'source-not-controller',
              'external-controller': '0.0.0.0:9090',
              'proxy-providers': {
                'source': {
                  'type': 'http',
                  'url': 'http://127.0.0.1:${sourceServer.port}/source',
                  'proxy': 'DIRECT',
                  'interval': 3600,
                },
              },
              'proxy-groups': [
                {
                  'name': 'selected',
                  'type': 'select',
                  'use': ['source'],
                },
              ],
              'rules': ['MATCH,selected'],
            }),
          );
      var approved = true;
      var reviews = 0;
      late final SingBoxUiHandler handler;
      ClashSubscriptionImporter importer(
        CoreApplicationSettings settings,
        Set<String> force,
      ) {
        final cache = CoreCachedProviderLoader(
          downloader: CoreProviderDownloader(
            transport: handler,
            userAgent: settings.userAgent,
          ),
          cache: providerCache,
        );
        return ClashSubscriptionImporter(
          resolve: (request) async => (await cache.loadProxy(
            request,
            force: force.contains(request.name),
          )).text,
        );
      }

      handler = SingBoxUiHandler.withProfileFiles(
        core,
        configPath: file.path,
        importer: (settings) => importer(settings, const {}),
        refreshImporter: importer,
        listeners: (profile, settings) async => CoreListenerSpec(
          mixedPort: settings.mixedPort,
          controllerPort: listeners.controllerPort,
          secret: listeners.secret,
          probe: listeners.probe,
          inbound: settings.inbound,
        ),
        review: (issues) async {
          reviews++;
          return approved;
        },
        onEvent: (_) {},
      );
      addTearDown(handler.close);
      final controller = CoreController.scoped(handler);
      final processes = <WindowsProcessWitness>[];
      final pids = <int>[];
      addTearDown(() {
        for (final process in processes) {
          process.close();
        }
      });
      void record() {
        final state = core.lifecycle.state as DesktopCoreRunning;
        pids.add(state.session.pid);
        processes.add(WindowsProcessWitness.open(state.session.pid));
      }

      try {
        await controller.start();
        record();
        await _expectSystem(pids.last);
        const params = SetupParams(
          selectedMap: {'selected': 'B'},
          testUrl: 'http://fixture.invalid',
        );
        expect(await controller.setupConfig(params: params, profileId: 11), '');
        expect(processes.last.hasExited, isTrue);
        record();
        expect(core.configuration!.profileId, 11);
        expect(sourceReads, 1);
        expect((await controller.getExternalProviders()).single.count, 2);
        expect(
          (await controller.getExternalProvider('source'))!.vehicleType,
          'HTTP',
        );
        expect(core.configuration!.listeners.secret, listeners.secret);
        expect(core.configuration!.listeners.inboundsEnabled, isFalse);
        expect(await controller.startListener(), isTrue);
        expect(processes.last.hasExited, isTrue);
        record();
        await _expectSystem(pids.last);
        Future<void> fetch(HttpClient client, String path) async {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/$path'),
          );
          expect(
            await utf8.decoder.bind(await request.close()).join(),
            'application-source-receipt',
          );
        }

        await controller.withRoutedClient(
          (client) => fetch(client, 'application'),
        );
        expect(
          (receipts, proxyA.receipts.length, proxyB.receipts.length),
          (1, 0, 1),
        );
        await controller.withOutboundClients('A', (clients) async {
          final scoped = clients.createClient();
          final request = await scoped.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/scoped'),
          );
          expect(
            await utf8.decoder.bind(await request.close()).join(),
            'application-source-receipt',
          );
        });
        expect(
          (receipts, proxyA.receipts.length, proxyB.receipts.length),
          (2, 1, 1),
        );
        await controller.withRoutedClient(
          (client) => fetch(client, 'direct'),
          outbound: 'DIRECT',
        );
        expect(
          (receipts, proxyA.receipts.length, proxyB.receipts.length),
          (3, 1, 1),
        );
        final probe = await controller.probe(
          ProbeParams(
            url: 'http://127.0.0.1:${origin.port}/probe',
            timeout: 5000,
            maxBody: 256,
          ),
        );
        expect(probe!.error, isNull);
        expect(probe.statusCode, 200);
        expect(probe.body, 'application-source-receipt');
        expect(probe.chains, contains('B'));
        expect(probe.chains, isNot(contains('A')));
        expect(probe.rule, isNotEmpty);
        expect(
          (receipts, proxyA.receipts.length, proxyB.receipts.length),
          (4, 1, 2),
        );
        final observedProcesses = await controller.getProcessTraffic();
        expect(observedProcesses, isNotNull);
        final caller = observedProcesses!.entries
            .where((entry) => entry.pid == pid)
            .toList();
        expect(caller, isNotEmpty);
        expect(caller.any((entry) => entry.path.isNotEmpty), isTrue);
        expect(
          caller.fold<int>(
            0,
            (total, entry) => total + entry.upload + entry.download,
          ),
          greaterThan(0),
        );
        final preview = await controller.previewRoute('fixture.invalid');
        expect(preview.status, CoreRoutePreviewStatus.resolved);
        expect(preview.chain, ['selected', 'B']);
        expect(preview.hops, ['B']);
        expect(
          (receipts, proxyA.receipts.length, proxyB.receipts.length),
          (4, 1, 2),
        );
        final committed = core.configuration;
        final session =
            (core.lifecycle.state as DesktopCoreRunning).session.sessionId;
        approved = false;
        var takeover = false;
        await expectLater(
          controller.setupConfig(
            params: params,
            profileId: 12,
            preloadInvoke: () async {
              takeover = true;
            },
          ),
          throwsA(isA<CoreAdapterException>()),
        );
        expect(takeover, isFalse);
        expect(identical(core.configuration, committed), isTrue);
        expect(
          (core.lifecycle.state as DesktopCoreRunning).session.sessionId,
          session,
        );
        expect(
          (await core.adapter.outbounds())
              .singleWhere((node) => node.name == 'selected')
              .selected,
          'B',
        );
        expect(reviews, 2);
        approved = true;
        final updatedPort = await freeLoopbackPort();
        await controller.updateConfig(
          defaultClashConfig
              .toUpdateParams(
                authentication: ['updated:new:password'],
                skipCertVerify: false,
              )
              .copyWith(
                mixedPort: updatedPort,
                ipv6: true,
                findProcessMode: FindProcessMode.always,
              ),
        );
        expect(processes.last.hasExited, isTrue);
        record();
        await _expectSystem(pids.last);
        expect(core.configuration!.listeners.mixedPort, updatedPort);
        expect(core.configuration!.listeners.secret, listeners.secret);
        expect(core.configuration!.profileId, 11);
        expect(
          (await core.adapter.outbounds())
              .singleWhere((node) => node.name == 'selected')
              .selected,
          'B',
        );
        await controller.withRoutedClient(
          (client) => fetch(client, 'after-settings-update'),
        );
        expect(
          (receipts, proxyA.receipts.length, proxyB.receipts.length),
          (5, 1, 3),
        );
        await expectLater(
          controller.updateConfig(
            defaultClashConfig
                .toUpdateParams(authentication: [], skipCertVerify: false)
                .copyWith(mixedPort: 0),
          ),
          throwsA(isA<CoreAdapterException>()),
        );
        expect(core.configuration!.listeners.mixedPort, updatedPort);
        expect(processes.last.hasExited, isFalse);
        await controller.updateExternalProvider(providerName: 'source');
        expect(processes.last.hasExited, isTrue);
        record();
        await _expectSystem(pids.last);
        expect(sourceReads, 2);
        expect((await controller.getExternalProviders()).single.count, 2);
        expect(
          (await core.adapter.outbounds())
              .singleWhere((node) => node.name == 'selected')
              .selected,
          'B',
        );
        expect(
          (receipts, proxyA.receipts.length, proxyB.receipts.length),
          (5, 1, 3),
        );
      } finally {
        await controller.close();
        await proxyA.close();
        await proxyB.close();
        await origin.close(force: true);
        await directory.delete(recursive: true);
      }
      expect(processes.every((process) => process.hasExited), isTrue);
      for (final process in processes) {
        process.close();
      }
      final result = File(_environment['HOTARU_NATIVE_HELPER_RESULT']!);
      final report = Map<String, dynamic>.from(
        jsonDecode(await result.readAsString()) as Map,
      );
      report['application_profile_handoff'] = true;
      report['application_http_current_and_direct'] = true;
      report['application_offline_preview'] = true;
      report['application_http_probe_observation'] = true;
      report['application_process_counters'] = true;
      report['application_runtime_update'] = true;
      report['application_provider_cache_refresh'] = true;
      (report.putIfAbsent('pids', () => <int>[]) as List).addAll(pids);
      await result.writeAsString(jsonEncode(report));
    },
    skip: _enabled ? false : 'Opt-in disposable Windows SCM integration only',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

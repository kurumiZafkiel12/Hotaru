import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/logs.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/method.dart';
import 'package:hotaru/core/maintenance.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/sing_box/desktop_core.dart';
import 'package:hotaru/core/sing_box/ui_handler.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/models/models.dart'
    show CoreEvent, SetupBase, Traffic, CoreMemoryStatsExt;
import 'package:mocktail/mocktail.dart';

import '../desktop/fakes.dart';
import 'support/telemetry_fixture.dart';

class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

class _Adapter extends Mock
    implements
        CoreAdapter,
        CoreLogSource,
        CoreTelemetry,
        CoreRuntimeMaintenance,
        CoreConnectionMaintenance {}

class _Binding implements SingBoxConfigurationBinding {
  @override
  final AcceptedSingBoxConfig current;
  final CoreAdapter adapter;
  _Binding(this.current, this.adapter);
  @override
  CoreAdapter createAdapter() => adapter;
  @override
  Future<CoreLifecycleResult> apply(AcceptedSingBoxConfig configuration) =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Lifecycle lifecycle;
  late _Adapter adapter;
  late SingBoxDesktopCore core;
  late CoreController controller;
  late SingBoxUiHandler handler;
  late StreamController<DesktopCoreState> events;
  late StreamController<DesktopCoreFailure> crashes;
  late List<CoreEvent> published;
  late DesktopCoreState state;
  late Duration elapsed;

  setUp(() async {
    lifecycle = _Lifecycle();
    adapter = _Adapter();
    events = StreamController.broadcast();
    crashes = StreamController.broadcast();
    published = [];
    elapsed = Duration.zero;
    state = DesktopCoreRunning(
      DesktopCoreSession(
        sessionId: 'one',
        lease: FakeProcessLease(
          owner: CoreProcessOwner.direct,
          pid: 4321,
          sessionId: 'one',
        ),
        connectionGeneration: 1,
      ),
    );
    when(() => lifecycle.state).thenAnswer((_) => state);
    when(() => lifecycle.states).thenAnswer((_) => events.stream);
    when(() => lifecycle.crashEvents).thenAnswer((_) => crashes.stream);
    when(() => lifecycle.close()).thenAnswer(
      (_) async => const CoreLifecycleResult(
        revision: 1,
        outcome: CoreLifecycleOutcome.applied,
      ),
    );
    when(() => adapter.close()).thenAnswer((_) async {});
    final preparer = SingBoxConfigPreparer();
    final result = await preparer.prepare(
      import: () async => CoreConfigImportResult(
        profile: CoreProfileSpec(
          nodes: const [
            CoreNodeSpec(tag: 'A', protocol: CoreNodeProtocol.direct),
            CoreNodeSpec(tag: 'B', protocol: CoreNodeProtocol.direct),
          ],
          selectors: [
            CoreSelectorSpec(tag: 'group', members: ['A', 'B']),
          ],
          finalOutbound: 'group',
        ),
        issues: [],
      ),
      listeners: const CoreListenerSpec(
        mixedPort: 17890,
        controllerPort: 19090,
        secret: 'fixture',
      ),
    );
    core = SingBoxDesktopCore.withConfiguration(
      lifecycle: lifecycle,
      configuration: _Binding(preparer.approve(result.candidate!), adapter),
    );
    handler = SingBoxUiHandler(
      core,
      onEvent: published.add,
      trafficElapsed: () => elapsed,
    );
    controller = CoreController.scoped(handler);
  });
  tearDown(() async {
    await controller.close();
    await events.close();
    await crashes.close();
  });

  test(
    'log controls are idempotent, map severity and stop publishing after cancellation',
    () async {
      final logs = StreamController<CoreLogMessage>.broadcast();
      when(() => adapter.logs()).thenAnswer((_) => logs.stream);
      await handler.stopLog().timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('stop log timed out'),
      );
      await handler.startLog();
      await handler.startLog();
      verify(() => adapter.logs()).called(1);
      logs.add(
        const CoreLogMessage(level: 'warn', payload: 'observed warning'),
      );
      await Future<void>.delayed(Duration.zero);
      final message = published.singleWhere(
        (event) => event.type == CoreEventType.log,
      );
      expect(message.data, containsPair('Payload', 'observed warning'));
      expect(message.data, containsPair('LogLevel', 'warning'));
      await handler.stopLog().timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('stop log timed out'),
      );
      logs.add(const CoreLogMessage(level: 'error', payload: 'late'));
      await Future<void>.delayed(Duration.zero);
      expect(
        published.where((event) => event.type == CoreEventType.log),
        hasLength(1),
      );
      await handler.startLog();
      await handler.close().timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('close timed out'),
      );
      logs.add(const CoreLogMessage(level: 'info', payload: 'after close'));
      await Future<void>.delayed(Duration.zero);
      expect(
        published.where((event) => event.type == CoreEventType.log),
        hasLength(1),
      );
      await expectLater(
        handler.startLog(),
        throwsA(isA<CoreAdapterException>()),
      );
      await logs.close().timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('source close timed out'),
      );
    },
  );

  test(
    'document validation is bounded, read only and localized without exposing source secrets',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-validate-',
      );
      addTearDown(() => directory.delete(recursive: true));
      addTearDown(() => AppLocalizations.load(const Locale('en')));
      final file = File('${directory.path}/profile.yaml');
      const source = 'proxies: []\nrules: [MATCH,DIRECT]\n';
      await file.writeAsString(source);
      expect(await controller.validateConfig(file.path), '');
      expect(await file.readAsString(), source);
      for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
        final strings = await AppLocalizations.load(locale);
        for (final text in [
          '[private-node-secret]',
          'private-node-secret: [',
          'age-encryption.org/v1\nprivate-node-secret',
        ]) {
          await file.writeAsString(text);
          expect(
            await controller.validateConfig(file.path),
            strings.importConfigInvalid,
          );
          expect(await file.readAsString(), text);
        }
        expect(
          await controller.validateConfig('${directory.path}/missing'),
          strings.importConfigInvalid,
        );
        await file.writeAsBytes([0xff]);
        expect(
          await controller.validateConfig(file.path),
          strings.importConfigInvalid,
        );
      }
      verifyZeroInteractions(adapter);
    },
  );

  test(
    'ordinary maintenance methods await native acknowledgement and propagate failure',
    () async {
      when(() => adapter.collectMemory()).thenAnswer((_) async {});
      when(() => adapter.resetDnsConnections()).thenAnswer((_) async {});
      when(() => adapter.closeConnections()).thenAnswer((_) async {});
      when(() => adapter.clearDnsCache()).thenAnswer((_) async {});
      await controller.requestGc();
      await controller.resetConnections();
      await controller.closeConnections();
      expect(await controller.clearDnsCache(), isTrue);
      verify(() => adapter.collectMemory()).called(1);
      verify(() => adapter.resetDnsConnections()).called(1);
      verify(() => adapter.closeConnections()).called(1);
      verify(() => adapter.clearDnsCache()).called(1);
      when(() => adapter.collectMemory()).thenThrow(
        const CoreAdapterException('runtime_maintenance_unavailable'),
      );
      await expectLater(
        controller.requestGc(),
        throwsA(isA<CoreAdapterException>()),
      );
    },
  );

  test(
    'memory cards use the owned host observation and reject late sessions',
    () async {
      when(() => adapter.telemetry()).thenAnswer(
        (_) async => CoreTelemetrySnapshot.fromJson(
          telemetryFixture()..['memory'] = observedMemoryFixture(),
        ),
      );
      final memory = await controller.getMemoryStats();
      expect(memory!.rss, 1000);
      expect(memory.runtimeTotal, 600);
      when(() => adapter.telemetry()).thenAnswer(
        (_) async => CoreTelemetrySnapshot.fromJson(telemetryFixture()),
      );
      expect(await controller.getMemoryStats(), isNull);
      when(() => adapter.telemetry()).thenAnswer(
        (_) async => CoreTelemetrySnapshot.fromJson(
          telemetryFixture()
            ..['memory'] = {...observedMemoryFixture(), 'rss': 0},
        ),
      );
      expect(await controller.getMemoryStats(), isNull);
      final pending = Completer<CoreTelemetrySnapshot>();
      when(() => adapter.telemetry()).thenAnswer((_) => pending.future);
      final read = controller.getMemoryStats();
      final checked = expectLater(read, throwsA(isA<CoreAdapterException>()));
      await Future<void>.delayed(Duration.zero);
      state = const DesktopCoreIdle();
      pending.complete(
        CoreTelemetrySnapshot.fromJson(
          telemetryFixture()..['memory'] = observedMemoryFixture(),
        ),
      );
      await checked;
    },
  );

  test(
    'node editing reads the applied profile and never treats a selector as a node',
    () async {
      expect(await controller.getProxyDefinition('A'), {
        'name': 'A',
        'type': 'direct',
      });
      expect(await controller.getProxyDefinition('group'), isNull);
      expect(await controller.getProxyDefinition('missing'), isNull);
      verifyZeroInteractions(adapter);
      final pending = controller.getProxyDefinition('B');
      state = const DesktopCoreIdle();
      await expectLater(pending, throwsA(isA<CoreAdapterException>()));
    },
  );

  test(
    'global selection exposes the client owned group without using API GLOBAL',
    () async {
      expect(controller.supportsGlobalOutbound, isTrue);
      expect(await controller.globalOutbound(), 'Hotaru GLOBAL');
      verifyZeroInteractions(adapter);
    },
  );

  test(
    'display speeds use monotonic elapsed time and total reads do not consume speed bytes',
    () async {
      var up = 10;
      var down = 20;
      when(() => adapter.telemetry()).thenAnswer(
        (_) async => CoreTelemetrySnapshot.fromJson(
          telemetryFixture(upload: up, download: down),
        ),
      );
      expect(await controller.getTraffic(false), const Traffic());
      elapsed = const Duration(seconds: 1);
      up = 50;
      down = 100;
      expect(
        await controller.getTotalTraffic(false),
        const Traffic(up: 50, down: 100),
      );
      elapsed = const Duration(seconds: 2);
      up = 110;
      down = 220;
      expect(
        await controller.getTraffic(false),
        const Traffic(up: 50, down: 100),
      );
      await handler.resetTraffic();
      expect(await controller.getTotalTraffic(false), const Traffic());
      elapsed = const Duration(seconds: 4);
      up = 150;
      down = 300;
      expect(
        await controller.getTotalTraffic(false),
        const Traffic(up: 40, down: 80),
      );
      expect(
        await controller.getTraffic(false),
        const Traffic(up: 20, down: 40),
      );
      expect((up, down), (150, 300));
    },
  );

  test(
    'traffic samples in one clock tick retain bytes for the next interval and regressions fail',
    () async {
      var up = 10;
      when(() => adapter.telemetry()).thenAnswer(
        (_) async =>
            CoreTelemetrySnapshot.fromJson(telemetryFixture(upload: up)),
      );
      await controller.getTraffic(false);
      up = 20;
      expect(await controller.getTraffic(false), const Traffic());
      elapsed = const Duration(seconds: 1);
      up = 30;
      expect((await controller.getTraffic(false)).up, 20);
      up = 29;
      await expectLater(
        controller.getTotalTraffic(false),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'traffic_counter_regressed',
          ),
        ),
      );
      up = 40;
      elapsed = const Duration(seconds: 2);
      expect((await controller.getTraffic(false)).up, 10);
      up = 9223372036854775807;
      elapsed = const Duration(seconds: 3);
      final large = await controller.getTraffic(false);
      expect(large.up, greaterThan(0));
      expect(large.up.isFinite, isTrue);
    },
  );

  test(
    'proxy-only totals are not fabricated from a bounded connection window',
    () async {
      await expectLater(
        controller.getTraffic(true),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'proxy_only_traffic_unavailable',
          ),
        ),
      );
      await expectLater(
        controller.getTotalTraffic(true),
        throwsA(isA<CoreAdapterException>()),
      );
      verifyNever(() => adapter.telemetry());
    },
  );

  test(
    'replaced sessions reject old samples and discard display offsets',
    () async {
      when(() => adapter.telemetry()).thenAnswer(
        (_) async => CoreTelemetrySnapshot.fromJson(
          telemetryFixture(upload: 100, download: 200),
        ),
      );
      await handler.resetTraffic();
      final pending = Completer<CoreTelemetrySnapshot>();
      when(() => adapter.telemetry()).thenAnswer((_) => pending.future);
      final reading = controller.getTotalTraffic(false);
      await Future<void>.delayed(Duration.zero);
      final checked = expectLater(
        reading,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      state = DesktopCoreRunning(
        DesktopCoreSession(
          sessionId: 'two',
          lease: FakeProcessLease(
            owner: CoreProcessOwner.direct,
            pid: 4322,
            sessionId: 'two',
          ),
          connectionGeneration: 2,
        ),
      );
      pending.complete(
        CoreTelemetrySnapshot.fromJson(
          telemetryFixture(upload: 150, download: 300),
        ),
      );
      await checked;
      when(() => adapter.telemetry()).thenAnswer(
        (_) async => CoreTelemetrySnapshot.fromJson(
          telemetryFixture(upload: 5, download: 6),
        ),
      );
      expect(
        await controller.getTotalTraffic(false),
        const Traffic(up: 5, down: 6),
      );
      expect(await controller.getTraffic(false), const Traffic());
      await controller.close();
      await expectLater(
        controller.getTraffic(false),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'closed',
          ),
        ),
      );
    },
  );

  test(
    'file preparation uses Dart without sending a legacy kernel RPC',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-ui-profile-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/profile.yaml',
      ).writeAsString('proxies: [{name: A, type: direct}]\nrules: ["MATCH,A"]');
      expect((await handler.getConfig(file.path))['rules'], ['MATCH,A']);
      final base = await handler.getProfileBase(file.path);
      expect((base.proxies, base.rules), (1, 1));
      expect((await handler.getProfileOutbounds(file.path))['proxies'], [
        {'name': 'A', 'type': 'direct'},
      ]);
      expect(
        await controller.buildProfile(
          SetupBase(path: file.path, overlay: '{}'),
        ),
        contains('MATCH,A'),
      );
      verifyZeroInteractions(adapter);
    },
  );

  test(
    'crash events carry a stable code and stop after terminal close',
    () async {
      crashes.add(
        DesktopCoreFailure(
          code: 'transport_disconnected',
          phase: DesktopCorePhase.running,
          revision: 1,
          cause: StateError('private fixture detail'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(published.single.type, CoreEventType.crash);
      expect(published.single.data, 'transport_disconnected');
      await controller.close();
      crashes.add(
        const DesktopCoreFailure(
          code: 'late',
          phase: DesktopCorePhase.closed,
          revision: 2,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(published, hasLength(1));
    },
  );

  test(
    'share links decode and file conversion use Dart and reject lossy options',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-ui-links-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const link = 'http://127.0.0.1:1080#Node';
      final file = await File(
        '${directory.path}/links.txt',
      ).writeAsString(link);
      final decoded = await controller.decodeShareLinks([link, '$link\n$link']);
      expect(decoded.map((nodes) => nodes.length), [1, 2]);
      final encoded = await controller.encodeShareLinks([
        decoded.first.single,
        {'name': 'direct', 'type': 'direct'},
      ]);
      expect(encoded, [link, '']);
      expect((await handler.convertProxies(file.path)).single['name'], 'Node');
      expect(await file.readAsString(), link);
      await expectLater(
        controller.decodeShareLinks([
          link,
          'trojan://fixture@127.0.0.1:443?pinSHA256=unsupported',
        ]),
        throwsA(
          isA<CoreMethodException>()
              .having(
                (error) => error.code,
                'code',
                'share_link_conversion_failed',
              )
              .having((error) => (error.details as Map)['input'], 'input', 1),
        ),
      );
      verifyZeroInteractions(adapter);
    },
  );

  test(
    'ordinary controller group conversion uses real native groups instead of the synthetic API GLOBAL',
    () async {
      when(() => adapter.outbounds()).thenAnswer(
        (_) async => const [
          CoreOutbound(
            name: 'GLOBAL',
            type: 'Fallback',
            members: ['group'],
            selected: 'group',
          ),
          CoreOutbound(
            name: 'Hotaru GLOBAL',
            type: 'Selector',
            members: ['A', 'B', 'group'],
            selected: 'group',
          ),
          CoreOutbound(
            name: 'group',
            type: 'Selector',
            members: ['A', 'B'],
            selected: 'B',
          ),
          CoreOutbound(name: 'A', type: 'Direct', members: []),
          CoreOutbound(name: 'B', type: 'Direct', members: []),
        ],
      );
      final groups = await controller.getProxiesGroups(
        sortType: ProxiesSortType.none,
        delayMap: {},
        selectedMap: {},
        defaultTestUrl: 'https://example.org',
      );
      expect(groups.map((group) => group.name), ['Hotaru GLOBAL', 'group']);
      expect(groups.first.hidden, isTrue);
      expect(groups.last.now, 'B');
      expect(groups.last.all.map((node) => node.name), ['A', 'B']);
      verifyNever(() => lifecycle.start());
    },
  );

  test(
    'proxy field validation uses shared Dart rules without contacting the running core',
    () async {
      final values = await controller.validateProxies([
        {
          'name': 'good',
          'type': 'http',
          'server': 'proxy.invalid',
          'port': 8080,
        },
        {
          'name': 'bad',
          'type': 'vless',
          'server': '127.0.0.1',
          'port': 443,
          'uuid': 'invalid',
        },
      ]);
      expect(values.first, isEmpty);
      expect(values.last, contains('invalid_uuid'));
      verifyZeroInteractions(adapter);
    },
  );

  test(
    'ordinary connection rows retain observed start, process and raw chain',
    () async {
      when(() => adapter.telemetry()).thenAnswer(
        (_) async => CoreTelemetrySnapshot.fromJson({
          ...telemetryFixture(),
          'active': [observedConnectionFixture()],
        }),
      );
      final row = (await controller.getConnections()).single;
      expect(row.id, 'connection');
      expect(row.start, DateTime.utc(2026, 11, 6, 11, 59));
      expect(row.metadata.processPath, r'C:\Apps\browser.exe');
      expect(row.metadata.process, 'browser.exe');
      expect(row.metadata.uid, 0);
      expect(row.chains, ['exit', 'selected']);
      expect(row.download, 20);
    },
  );

  test(
    'truncated connection data is not passed off as a complete list',
    () async {
      when(() => adapter.telemetry()).thenAnswer(
        (_) async => CoreTelemetrySnapshot.fromJson({
          ...telemetryFixture(),
          'active_truncated': true,
        }),
      );
      await expectLater(
        controller.getConnections(),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'connection_window_truncated',
          ),
        ),
      );
    },
  );

  test(
    'bridge has scoped clients but never falls back to old kernel RPC methods',
    () async {
      expect(controller.supportsOutboundClients, isTrue);
      await expectLater(
        handler.validateFilters(['not-implemented']),
        throwsA(
          isA<CoreMethodException>().having(
            (error) => error.code,
            'code',
            'sing_box_method_unavailable',
          ),
        ),
      );
      state = const DesktopCoreIdle();
      await expectLater(
        controller.getProxies(),
        throwsA(isA<CoreAdapterException>()),
      );
      verifyNever(() => adapter.outbounds());
    },
  );
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/method.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/sing_box/desktop_core.dart';
import 'package:hotaru/core/sing_box/ui_handler.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:mocktail/mocktail.dart';

import '../desktop/fakes.dart';
import 'support/telemetry_fixture.dart';

class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

class _Adapter extends Mock implements CoreAdapter, CoreTelemetry {}

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
  late _Lifecycle lifecycle;
  late _Adapter adapter;
  late SingBoxDesktopCore core;
  late CoreController controller;
  late SingBoxUiHandler handler;
  late StreamController<DesktopCoreState> events;
  late DesktopCoreState state;

  setUp(() async {
    lifecycle = _Lifecycle();
    adapter = _Adapter();
    events = StreamController.broadcast();
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
    handler = SingBoxUiHandler(core);
    controller = CoreController.scoped(handler);
  });
  tearDown(() async {
    await controller.close();
    await events.close();
  });

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
        handler.validateConfig('not-read'),
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

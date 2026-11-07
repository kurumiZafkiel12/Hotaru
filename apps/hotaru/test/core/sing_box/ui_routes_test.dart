import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/sing_box/desktop_core.dart';
import 'package:hotaru/core/sing_box/ui_routes.dart';
import 'package:hotaru/models/models.dart';
import 'package:mocktail/mocktail.dart';

import '../desktop/fakes.dart';

class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

class _Adapter extends Mock implements CoreAdapter, CoreRoutingModes {}

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

DesktopCoreRunning _running(String id) => DesktopCoreRunning(
  DesktopCoreSession(
    sessionId: id,
    lease: FakeProcessLease(
      owner: CoreProcessOwner.direct,
      pid: 4321,
      sessionId: id,
    ),
    connectionGeneration: 1,
  ),
);

void main() {
  late _Lifecycle lifecycle;
  late _Adapter adapter;
  late SingBoxDesktopCore core;
  late SingBoxUiRoutes routes;
  late StreamController<DesktopCoreState> states;
  late DesktopCoreState state;
  late String selected;
  late CoreRoutingMode mode;
  late List<RouteSnapshot> published;
  late List<Object> errors;
  var reverse = false;

  setUpAll(() => registerFallbackValue(CoreRoutingMode.rule));
  setUp(() async {
    lifecycle = _Lifecycle();
    adapter = _Adapter();
    states = StreamController.broadcast();
    state = _running('one');
    selected = 'B';
    mode = CoreRoutingMode.rule;
    reverse = false;
    published = [];
    errors = [];
    when(() => lifecycle.state).thenAnswer((_) => state);
    when(() => lifecycle.states).thenAnswer((_) => states.stream);
    when(() => lifecycle.close()).thenAnswer((_) async {
      state = const DesktopCoreClosed(1);
      return const CoreLifecycleResult(
        revision: 1,
        outcome: CoreLifecycleOutcome.applied,
      );
    });
    when(() => adapter.close()).thenAnswer((_) async {});
    when(() => adapter.routingMode()).thenAnswer((_) async => mode);
    when(() => adapter.setRoutingMode(any())).thenAnswer(
      (call) async => mode = call.positionalArguments.single as CoreRoutingMode,
    );
    when(() => adapter.selectOutbound(any(), any())).thenAnswer(
      (call) async => selected = call.positionalArguments[1] as String,
    );
    when(() => adapter.outbounds()).thenAnswer((_) async {
      final nodes = [
        CoreOutbound(
          name: 'group',
          type: 'Selector',
          members: const ['A', 'B'],
          selected: selected,
        ),
        const CoreOutbound(name: 'A', type: 'Direct', members: []),
        const CoreOutbound(name: 'B', type: 'Direct', members: []),
      ];
      return reverse ? nodes.reversed.toList() : nodes;
    });
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
    routes = SingBoxUiRoutes(
      core: core,
      onChange: published.add,
      onError: (error, _) => errors.add(error),
    );
  });
  tearDown(() async {
    await core.close();
    await routes.close();
    await states.close();
  });

  test(
    'unchanged or reordered policy does not invent a route change',
    () async {
      expect(await routes.watch(true), const RouteSnapshot(coreEpoch: 1));
      reverse = true;
      expect(await routes.snapshot(), const RouteSnapshot(coreEpoch: 1));
      expect(published, [const RouteSnapshot(coreEpoch: 1)]);
      selected = 'A';
      expect(
        await routes.snapshot(),
        const RouteSnapshot(coreEpoch: 1, routeVersion: 1),
      );
      mode = CoreRoutingMode.global;
      expect(
        await routes.snapshot(),
        const RouteSnapshot(coreEpoch: 1, routeVersion: 2),
      );
      expect(errors, isEmpty);
      verifyNever(() => lifecycle.start());
    },
  );

  test(
    'selection acknowledges actual readback and repeated selection is a no-op',
    () async {
      final changed = await routes.select('group', 'A');
      expect(changed.changed, isTrue);
      expect(changed.coreEpoch, 1);
      expect(changed.routeVersion, 1);
      expect((await routes.select('group', 'A')).changed, isFalse);
      verify(() => adapter.selectOutbound('group', 'A')).called(1);
      await expectLater(
        routes.select('group', 'missing'),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'invalid_selection',
          ),
        ),
      );
    },
  );

  test('successful response without a changed selection is rejected', () async {
    when(() => adapter.selectOutbound('group', 'A')).thenAnswer((_) async {});
    await expectLater(
      routes.select('group', 'A'),
      throwsA(
        isA<CoreAdapterException>().having(
          (error) => error.code,
          'code',
          'selection_changed',
        ),
      ),
    );
  });

  test(
    'mode mutations use actual state and unchanged mode sends no write',
    () async {
      await routes.setMode(CoreRoutingMode.global);
      expect(await routes.mode(), CoreRoutingMode.global);
      expect(
        await routes.snapshot(),
        const RouteSnapshot(coreEpoch: 1, routeVersion: 1),
      );
      await routes.setMode(CoreRoutingMode.global);
      verify(() => adapter.setRoutingMode(CoreRoutingMode.global)).called(1);
    },
  );

  test(
    'a new process gets a new epoch without adopting a late selection result',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      when(() => adapter.selectOutbound('group', 'A')).thenAnswer((_) {
        entered.complete();
        return release.future;
      });
      final selection = routes.select('group', 'A');
      final rejected = expectLater(
        selection,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      await entered.future;
      state = _running('two');
      release.complete();
      await rejected;
      expect(await routes.snapshot(), const RouteSnapshot(coreEpoch: 2));
      expect(published, isEmpty);
    },
  );

  test('detach supersedes a watch still awaiting its first response', () async {
    final pending = Completer<CoreRoutingMode>();
    var reads = 0;
    when(
      () => adapter.routingMode(),
    ).thenAnswer((_) => ++reads == 1 ? pending.future : Future.value(mode));
    final first = routes.watch(true);
    await routes.watch(false);
    pending.complete(mode);
    await first;
    expect(published, isEmpty);
    expect(errors, isEmpty);
  });

  test('an inconsistent mode snapshot is not published', () async {
    var reads = 0;
    when(() => adapter.routingMode()).thenAnswer(
      (_) async => ++reads == 1 ? CoreRoutingMode.rule : CoreRoutingMode.global,
    );
    await expectLater(
      routes.snapshot(),
      throwsA(
        isA<CoreAdapterException>().having(
          (error) => error.code,
          'code',
          'route_changed',
        ),
      ),
    );
    expect(published, isEmpty);
    expect(await routes.snapshot(), const RouteSnapshot(coreEpoch: 1));
  });

  test('polling observes automatic selections only while watched', () async {
    await routes.close();
    final changed = Completer<void>();
    routes = SingBoxUiRoutes(
      core: core,
      interval: const Duration(milliseconds: 10),
      onChange: (snapshot) {
        published.add(snapshot);
        if (snapshot.routeVersion == 1 && !changed.isCompleted) {
          changed.complete();
        }
      },
      onError: (error, _) => errors.add(error),
    );
    await routes.watch(true);
    selected = 'A';
    await changed.future.timeout(const Duration(seconds: 2));
    await routes.watch(false);
    final before = published.length;
    selected = 'B';
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(published, hasLength(before));
    expect(errors, isEmpty);
    verifyNever(() => lifecycle.start());
  });
}

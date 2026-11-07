import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/rule_set.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/sing_box/desktop_core.dart';
import 'package:hotaru/core/sing_box/ui_routes.dart';
import 'package:mocktail/mocktail.dart';

import '../desktop/fakes.dart';

class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

class _Adapter extends Mock implements CoreAdapter, CoreRoutingModes {}

class _Binding implements SingBoxConfigurationBinding {
  @override
  AcceptedSingBoxConfig current;
  final CoreAdapter adapter;
  final Future<CoreLifecycleResult> Function(AcceptedSingBoxConfig) submit;

  _Binding(this.current, this.adapter, this.submit);

  @override
  CoreAdapter createAdapter() => adapter;
  @override
  Future<CoreLifecycleResult> apply(AcceptedSingBoxConfig configuration) =>
      submit(configuration);
}

Future<AcceptedSingBoxConfig> _configuration({
  int id = 1,
  CoreRoutingMode mode = CoreRoutingMode.rule,
}) async {
  final preparer = SingBoxConfigPreparer();
  final result = await preparer.prepare(
    profileId: id,
    import: () async => CoreConfigImportResult(
      profile: CoreProfileSpec(
        nodes: const [
          CoreNodeSpec(tag: 'A', protocol: CoreNodeProtocol.direct),
          CoreNodeSpec(tag: 'B', protocol: CoreNodeProtocol.direct),
        ],
        selectors: [
          CoreSelectorSpec(tag: 'group', members: ['A', 'B'], selected: 'A'),
        ],
        finalOutbound: 'group',
        ruleSets: [
          CoreRuleSetSpec(
            tag: 'fixture-$id',
            kind: CoreRuleSetKind.domain,
            suffixes: ['profile-$id.invalid'],
          ),
        ],
        rules: [
          CoreRouteRule(
            kind: CoreRuleKind.ruleSet,
            value: 'fixture-$id',
            outbound: 'group',
          ),
        ],
      ),
      issues: [],
    ),
    listeners: CoreListenerSpec(
      mixedPort: 17890,
      controllerPort: 19090,
      secret: 'fixture-$id',
      initialMode: mode,
    ),
  );
  return preparer.approve(result.candidate!);
}

DesktopCoreRunning _running(int generation) => DesktopCoreRunning(
  DesktopCoreSession(
    sessionId: 'session-$generation',
    lease: FakeProcessLease(
      owner: CoreProcessOwner.direct,
      pid: 4321 + generation,
      sessionId: 'session-$generation',
    ),
    connectionGeneration: generation,
  ),
);

void main() {
  late _Lifecycle lifecycle;
  late _Adapter adapter;
  late _Binding binding;
  late SingBoxDesktopCore core;
  late SingBoxUiRoutes routes;
  late StreamController<DesktopCoreState> states;
  late DesktopCoreState state;
  late CoreRoutingMode mode;
  late String selected;
  late String global;
  late List<AcceptedSingBoxConfig> submitted;
  late Future<CoreLifecycleResult> Function(AcceptedSingBoxConfig) submit;
  var generation = 1;

  Future<CoreLifecycleResult> commit(
    AcceptedSingBoxConfig configuration,
  ) async {
    binding.current = configuration;
    selected = configuration.profile.selectors.single.selected ?? 'A';
    global = configuration.listeners.globalSelection ?? 'group';
    mode = configuration.listeners.initialMode;
    state = _running(++generation);
    states.add(state);
    return CoreLifecycleResult(
      revision: generation,
      outcome: CoreLifecycleOutcome.applied,
      session: (state as DesktopCoreRunning).session,
    );
  }

  setUpAll(() => registerFallbackValue(CoreRoutingMode.rule));
  setUp(() async {
    lifecycle = _Lifecycle();
    adapter = _Adapter();
    states = StreamController.broadcast();
    state = _running(1);
    generation = 1;
    selected = 'B';
    global = 'B';
    mode = CoreRoutingMode.global;
    submitted = [];
    submit = commit;
    when(() => lifecycle.state).thenAnswer((_) => state);
    when(() => lifecycle.states).thenAnswer((_) => states.stream);
    when(() => lifecycle.close()).thenAnswer((_) async {
      state = const DesktopCoreClosed(100);
      return const CoreLifecycleResult(
        revision: 100,
        outcome: CoreLifecycleOutcome.applied,
      );
    });
    when(() => adapter.close()).thenAnswer((_) async {});
    when(() => adapter.routingMode()).thenAnswer((_) async => mode);
    when(() => adapter.selectOutbound(any(), any())).thenAnswer((call) async {
      selected = call.positionalArguments[1] as String;
    });
    when(() => adapter.setRoutingMode(any())).thenAnswer((call) async {
      mode = call.positionalArguments.single as CoreRoutingMode;
    });
    when(() => adapter.outbounds()).thenAnswer(
      (_) async => [
        CoreOutbound(
          name: 'group',
          type: 'Selector',
          members: const ['A', 'B'],
          selected: selected,
        ),
        CoreOutbound(
          name: 'Hotaru GLOBAL',
          type: 'Selector',
          members: const ['A', 'B', 'group'],
          selected: global,
        ),
        const CoreOutbound(name: 'A', type: 'Direct', members: []),
        const CoreOutbound(name: 'B', type: 'Direct', members: []),
      ],
    );
    binding = _Binding(await _configuration(), adapter, (configuration) {
      submitted.add(configuration);
      return submit(configuration);
    });
    core = SingBoxDesktopCore.withConfiguration(
      lifecycle: lifecycle,
      configuration: binding,
    );
    routes = SingBoxUiRoutes(
      core: core,
      onChange: (_) {},
      onError: (error, trace) => fail('$error\n$trace'),
    );
  });
  tearDown(() async {
    await core.close();
    await routes.close();
    await states.close();
  });

  test(
    'listener changes adopt a configuration committed outside this UI command queue',
    () async {
      await routes.setInbounds(false);
      final replacement = await _configuration(
        id: 2,
        mode: CoreRoutingMode.direct,
      );
      await commit(replacement);
      await routes.setInbounds(false);
      expect(binding.current.profileId, 2);
      expect(binding.current.listeners.inboundsEnabled, isFalse);
      expect((selected, mode), ('A', CoreRoutingMode.direct));
    },
  );

  test(
    'acknowledged policy mutations queued during preparation are not overwritten by the prepared snapshot',
    () async {
      final pause = routes.setInbounds(false);
      final choose = routes.select('group', 'A');
      final changeMode = routes.setMode(CoreRoutingMode.direct);
      await Future.wait([pause, choose, changeMode]);
      expect(selected, 'A');
      expect(mode, CoreRoutingMode.direct);
      await routes.setInbounds(true);
      expect(selected, 'A');
      expect(mode, CoreRoutingMode.direct);
    },
  );

  test(
    'pause and resume retain actual selections and mode without stopping the control owner',
    () async {
      final original = binding.current;
      expect(await routes.setInbounds(false), isTrue);
      expect(binding.current.listeners.inboundsEnabled, isFalse);
      final quiet = jsonDecode(
        utf8.decode(binding.current.bootstrap.bytes),
      )['config'];
      expect(quiet['inbounds'], isEmpty);
      expect(quiet['experimental']['clash_api']['default_mode'], 'global');
      expect(
        quiet['route']['rule_set'].single['rules'].single['domain_suffix'],
        ['profile-1.invalid'],
      );
      expect((selected, global, mode), ('B', 'B', CoreRoutingMode.global));
      expect(binding.current.profileId, original.profileId);
      expect(await routes.setInbounds(true), isTrue);
      expect(binding.current.listeners.inboundsEnabled, isTrue);
      expect(binding.current.profile.ruleSets.single.suffixes, [
        'profile-1.invalid',
      ]);
      expect((selected, global, mode), ('B', 'B', CoreRoutingMode.global));
      expect(submitted, hasLength(2));
      verifyNever(() => lifecycle.stop());
      verifyNever(() => lifecycle.start());
    },
  );

  test(
    'a settled listener state is a no-op while restart captures actual policy',
    () async {
      expect(await routes.setInbounds(true), isTrue);
      expect(submitted, isEmpty);
      expect((await routes.restart()).outcome, CoreLifecycleOutcome.applied);
      expect(submitted, hasLength(1));
      expect((selected, global, mode), ('B', 'B', CoreRoutingMode.global));
    },
  );

  test('rapid listener requests discard superseded preparation', () async {
    final pause = routes.setInbounds(false);
    final resume = routes.setInbounds(true);
    expect(await Future.wait([pause, resume]), [true, true]);
    expect(submitted, hasLength(1));
    expect(submitted.single.listeners.inboundsEnabled, isTrue);
  });

  test(
    'a new reviewed profile combines with the latest pause intent instead of adopting old selections',
    () async {
      final replacement = await _configuration(
        id: 2,
        mode: CoreRoutingMode.direct,
      );
      final apply = routes.applyConfiguration(replacement);
      final pause = routes.setInbounds(false);
      expect((await apply).outcome, CoreLifecycleOutcome.superseded);
      expect(await pause, isTrue);
      expect(submitted, hasLength(1));
      expect(binding.current.profileId, 2);
      expect(binding.current.listeners.secret, 'fixture-2');
      expect(binding.current.listeners.inboundsEnabled, isFalse);
      expect((selected, mode), ('A', CoreRoutingMode.direct));
    },
  );

  test(
    'a newer listener intent reaches lifecycle convergence before the old activation completes',
    () async {
      final entered = Completer<void>();
      final pending = Completer<CoreLifecycleResult>();
      submit = (configuration) {
        if (submitted.length == 1) {
          state = const DesktopCoreStarting(
            revision: 2,
            sessionId: 'starting-2',
          );
          entered.complete();
          return pending.future;
        }
        return commit(configuration).then((result) {
          pending.complete(
            const CoreLifecycleResult(
              revision: 2,
              outcome: CoreLifecycleOutcome.superseded,
            ),
          );
          return result;
        });
      };
      final pause = routes.setInbounds(false);
      await entered.future.timeout(const Duration(seconds: 2));
      final resume = routes.setInbounds(true);
      expect(await resume.timeout(const Duration(seconds: 2)), isTrue);
      expect(await pause, isTrue);
      expect(submitted, hasLength(2));
      expect(binding.current.listeners.inboundsEnabled, isTrue);
      expect((selected, global, mode), ('B', 'B', CoreRoutingMode.global));
    },
  );

  test(
    'failed replacement discards failed intent and leaves the committed configuration authoritative',
    () async {
      final original = binding.current;
      submit = (_) => Future.error(StateError('fixture activation failure'));
      await expectLater(routes.setInbounds(false), throwsStateError);
      expect(binding.current, same(original));
      submit = commit;
      await routes.restart();
      expect(binding.current.listeners.inboundsEnabled, isTrue);
      expect((selected, global, mode), ('B', 'B', CoreRoutingMode.global));
    },
  );

  test(
    'terminal close cancels preparation without submitting another process plan',
    () async {
      final pending = routes.setInbounds(false);
      await routes.close();
      expect(await pending, isTrue);
      expect(submitted, isEmpty);
      await expectLater(
        routes.applyConfiguration(binding.current),
        throwsA(isA<CoreAdapterException>()),
      );
    },
  );
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/sing_box/desktop_core.dart';
import 'package:mocktail/mocktail.dart';

import '../desktop/fakes.dart';

class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

class _Adapter extends Mock implements CoreAdapter, CoreRoutingModes {}

class _Binding implements SingBoxConfigurationBinding {
  @override
  AcceptedSingBoxConfig current;
  final CoreAdapter adapter;
  _Binding(this.current, this.adapter);
  @override
  CoreAdapter createAdapter() => adapter;
  @override
  Future<CoreLifecycleResult> apply(AcceptedSingBoxConfig configuration) =>
      throw UnimplementedError();
}

const _outbounds = [
  CoreOutbound(
    name: 'group',
    type: 'Selector',
    members: ['a', 'b'],
    selected: 'b',
  ),
];
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

Future<AcceptedSingBoxConfig> _configuration({
  String finalOutbound = 'group',
}) async {
  final prep = SingBoxConfigPreparer();
  final result = await prep.prepare(
    import: () async => CoreConfigImportResult(
      profile: CoreProfileSpec(
        nodes: const [
          CoreNodeSpec(tag: 'a', protocol: CoreNodeProtocol.direct),
          CoreNodeSpec(tag: 'b', protocol: CoreNodeProtocol.direct),
        ],
        selectors: [
          CoreSelectorSpec(tag: 'group', members: const ['a', 'b']),
        ],
        finalOutbound: finalOutbound,
        rules: const [
          CoreRouteRule(
            kind: CoreRuleKind.domainSuffix,
            value: 'example.org',
            outbound: 'group',
          ),
        ],
      ),
      issues: [],
    ),
    listeners: const CoreListenerSpec(
      mixedPort: 17890,
      controllerPort: 19090,
      secret: 'fixture',
    ),
  );
  return prep.approve(result.candidate!);
}

void main() {
  late _Lifecycle lifecycle;
  late _Adapter adapter;
  late _Binding binding;
  late SingBoxDesktopCore core;
  late StreamController<DesktopCoreState> events;
  late DesktopCoreState state;

  setUp(() async {
    lifecycle = _Lifecycle();
    adapter = _Adapter();
    binding = _Binding(await _configuration(), adapter);
    events = StreamController.broadcast();
    state = _running('one');
    when(() => lifecycle.state).thenAnswer((_) => state);
    when(() => lifecycle.states).thenAnswer((_) => events.stream);
    when(() => lifecycle.close()).thenAnswer(
      (_) async => const CoreLifecycleResult(
        revision: 1,
        outcome: CoreLifecycleOutcome.applied,
      ),
    );
    when(() => adapter.close()).thenAnswer((_) async {});
    when(
      () => adapter.routingMode(),
    ).thenAnswer((_) async => CoreRoutingMode.rule);
    when(() => adapter.outbounds()).thenAnswer((_) async => _outbounds);
    core = SingBoxDesktopCore.withConfiguration(
      lifecycle: lifecycle,
      configuration: binding,
    );
  });
  tearDown(() async {
    await core.close();
    await events.close();
  });

  test(
    'preview uses committed IR and actual selector, without dialing or changing a selection',
    () async {
      final preview = await core.previewRoute('www.example.org');
      expect(preview.status, CoreRoutePreviewStatus.resolved);
      expect(preview.chain, ['group', 'b']);
      expect(preview.ruleIndex, 0);
      verify(() => adapter.outbounds()).called(2);
      verify(() => adapter.routingMode()).called(2);
      verifyNever(() => lifecycle.start());
      verifyNoMoreInteractions(adapter);
    },
  );

  test('final direct route needs no selector recheck', () async {
    binding.current = await _configuration(finalOutbound: 'a');
    final preview = await core.previewRoute('other.example');
    expect(preview.chain, ['a']);
    expect(preview.rule, isNull);
    verify(() => adapter.outbounds()).called(1);
  });

  test(
    'mode changes invalidate a preview from the same process and selectors',
    () async {
      var reads = 0;
      when(() => adapter.routingMode()).thenAnswer(
        (_) async =>
            ++reads == 1 ? CoreRoutingMode.rule : CoreRoutingMode.direct,
      );
      await expectLater(
        core.previewRoute('example.org'),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'route_changed',
          ),
        ),
      );
    },
  );

  test(
    'a mode change during the final selector read invalidates the preview',
    () async {
      var mode = CoreRoutingMode.rule;
      var reads = 0;
      when(() => adapter.routingMode()).thenAnswer((_) async => mode);
      when(() => adapter.outbounds()).thenAnswer((_) async {
        if (++reads == 2) mode = CoreRoutingMode.direct;
        return _outbounds;
      });
      await expectLater(
        core.previewRoute('example.org'),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'route_changed',
          ),
        ),
      );
    },
  );

  test(
    'selector change during preview is never shown as the current route',
    () async {
      var reads = 0;
      when(() => adapter.outbounds()).thenAnswer(
        (_) async => ++reads == 1
            ? _outbounds
            : const [
                CoreOutbound(
                  name: 'group',
                  type: 'Selector',
                  members: ['a', 'b'],
                  selected: 'a',
                ),
              ],
      );
      await expectLater(
        core.previewRoute('www.example.org'),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'route_changed',
          ),
        ),
      );
    },
  );

  test(
    'a detour group selection change also invalidates the physical path',
    () async {
      final prep = SingBoxConfigPreparer();
      final prepared = await prep.prepare(
        import: () async => CoreConfigImportResult(
          profile: CoreProfileSpec(
            nodes: const [
              CoreNodeSpec(
                tag: 'exit',
                protocol: CoreNodeProtocol.http,
                server: '127.0.0.1',
                port: 8080,
                detour: 'relays',
              ),
              CoreNodeSpec(
                tag: 'a',
                protocol: CoreNodeProtocol.http,
                server: '127.0.0.1',
                port: 8081,
              ),
              CoreNodeSpec(
                tag: 'b',
                protocol: CoreNodeProtocol.http,
                server: '127.0.0.1',
                port: 8082,
              ),
            ],
            selectors: [
              CoreSelectorSpec(tag: 'relays', members: ['a', 'b']),
            ],
            finalOutbound: 'exit',
          ),
          issues: [],
        ),
        listeners: const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      binding.current = prep.approve(prepared.candidate!);
      var reads = 0;
      when(() => adapter.outbounds()).thenAnswer(
        (_) async => [
          CoreOutbound(
            name: 'relays',
            type: 'Selector',
            members: const ['a', 'b'],
            selected: ++reads == 1 ? 'a' : 'b',
          ),
        ],
      );
      await expectLater(
        core.previewRoute('example.org'),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'route_changed',
          ),
        ),
      );
    },
  );

  test(
    'a restart while reading groups rejects the old profile snapshot',
    () async {
      when(() => adapter.outbounds()).thenAnswer((_) async {
        state = _running('two');
        return _outbounds;
      });
      await expectLater(
        core.previewRoute('www.example.org'),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'session_changed',
          ),
        ),
      );
    },
  );

  test(
    'replacing the configuration invalidates the preview even with a reused test session',
    () async {
      final next = await _configuration(finalOutbound: 'a');
      when(() => adapter.outbounds()).thenAnswer((_) async {
        binding.current = next;
        return _outbounds;
      });
      await expectLater(
        core.previewRoute('www.example.org'),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'session_changed',
          ),
        ),
      );
    },
  );

  test('idle preview never starts a process or probes the domain', () async {
    state = const DesktopCoreIdle();
    await expectLater(
      core.previewRoute('www.example.org'),
      throwsA(
        isA<CoreAdapterException>().having(
          (e) => e.code,
          'code',
          'applied_profile_unavailable',
        ),
      ),
    );
    verifyNever(() => adapter.outbounds());
    verifyNever(() => lifecycle.start());
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/desktop/transport.dart';

import 'fakes.dart';

final class _Plan implements DesktopCoreLauncherResolver, CoreProcessLauncher {
  final int pidBase;
  final List<FakeProcessLease> leases = [];
  final List<FakeDesktopCoreTransport> transports = [];
  late final DesktopCoreLaunchPlan plan = DesktopCoreLaunchPlan(
    transportFactory: () {
      final transport = FakeDesktopCoreTransport(
        state: DesktopTransportState.ready,
      );
      transports.add(transport);
      return transport;
    },
    launcherResolver: this,
  );
  Completer<void>? gate;
  Error? startError;
  bool connect = true;

  _Plan(this.pidBase);

  @override
  Future<CoreProcessLauncher> resolve() async => this;

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    final transport = transports.last;
    final lease = FakeProcessLease(
      sessionId: sessionId,
      owner: CoreProcessOwner.helper,
      pid: pidBase + leases.length,
    );
    leases.add(lease);
    await gate?.future;
    if (startError case final error?) throw error;
    if (connect) scheduleMicrotask(() => transport.connect(pid: lease.pid));
    return lease;
  }
}

DesktopCoreLifecycle _owner(_Plan initial) => DesktopCoreLifecycle.withPlan(
  plan: initial.plan,
  verifyPeerPid: true,
  timeouts: const DesktopCoreTimeouts(
    ready: Duration(seconds: 1),
    connection: Duration(seconds: 1),
    disconnection: Duration(seconds: 1),
  ),
);

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await pumpEventQueue(times: 2);
  }
  expect(ready(), isTrue);
}

void main() {
  test(
    'running publication and committed configuration are one snapshot',
    () async {
      final a = _Plan(100);
      final b = _Plan(200);
      final core = _owner(a);
      addTearDown(core.close);
      final published = <DesktopCoreLaunchPlan>[];
      final listener = core.states.listen((state) {
        if (state is DesktopCoreRunning && state.session.pid == 200) {
          published.add(core.committedPlan);
        }
      });
      addTearDown(listener.cancel);
      await core.start();
      await core.applyConfiguration(b.plan);
      await pumpEventQueue();
      expect(published, [same(b.plan)]);
    },
  );

  test(
    'restart from a replacement notification keeps the new configuration',
    () async {
      final a = _Plan(100);
      final b = _Plan(200);
      final core = _owner(a);
      addTearDown(core.close);
      Future<CoreLifecycleResult>? restarted;
      final listener = core.states.listen((state) {
        if (state is DesktopCoreRunning && state.session.pid == 200) {
          restarted = core.restart();
        }
      });
      addTearDown(listener.cancel);
      await core.start();
      await core.applyConfiguration(b.plan);
      await _until(() => restarted != null);
      expect((await restarted!).session!.pid, 200);
      expect(a.leases, hasLength(1));
      expect(b.leases, hasLength(1));
      expect(core.committedPlan, same(b.plan));
      await core.restart();
      expect(b.leases, hasLength(2));
      expect((core.state as DesktopCoreRunning).session.pid, 201);
    },
  );

  test(
    'replacement commits only after its owned session is connected',
    () async {
      final a = _Plan(100);
      final b = _Plan(200)..gate = Completer<void>();
      final core = _owner(a);
      addTearDown(core.close);
      await core.start();
      final changed = core.applyConfiguration(b.plan);
      await _until(() => b.leases.isNotEmpty);
      expect(core.committedPlan, same(a.plan));
      expect(a.leases.single.stopCount, 1);
      b.gate!.complete();
      expect((await changed).session!.pid, 200);
      expect(core.committedPlan, same(b.plan));
      await core.restart();
      expect(b.leases.length, 2);
      expect(b.leases.first.stopCount, 1);
    },
  );

  test(
    'failed activation restores the last working plan and reports failure',
    () async {
      final a = _Plan(100);
      final b = _Plan(200)..startError = StateError('rejected');
      final core = _owner(a);
      addTearDown(core.close);
      await core.start();
      await expectLater(
        core.applyConfiguration(b.plan),
        throwsA(
          isA<DesktopCoreFailure>().having(
            (e) => e.code,
            'code',
            'configuration_rejected_previous_restored',
          ),
        ),
      );
      expect(core.state, isA<DesktopCoreRunning>());
      expect(core.committedPlan, same(a.plan));
      expect((core.state as DesktopCoreRunning).session.pid, 101);
      expect(a.leases.first.stopCount, 1);
    },
  );

  for (final terminal in [false, true]) {
    test(
      '${terminal ? 'close' : 'stop'} preempts replacement without recovery',
      () async {
        final a = _Plan(100);
        final b = _Plan(200)..gate = Completer<void>();
        final core = _owner(a);
        addTearDown(core.close);
        await core.start();
        final changed = core.applyConfiguration(b.plan);
        await _until(() => b.leases.isNotEmpty);
        final stopped = terminal ? core.close() : core.stop();
        b.gate!.complete();
        expect((await changed).outcome, CoreLifecycleOutcome.superseded);
        await stopped;
        expect(a.leases.length, 1);
        expect(b.leases.single.stopCount, 1);
        expect(
          core.state,
          terminal ? isA<DesktopCoreClosed>() : isA<DesktopCoreIdle>(),
        );
        if (terminal) {
          await expectLater(
            core.applyConfiguration(a.plan),
            throwsA(isA<DesktopCoreFailure>()),
          );
        } else {
          await core.start();
          expect(core.committedPlan, same(a.plan));
        }
      },
    );
  }

  test(
    'a newer plan supersedes a pending process before publishing running',
    () async {
      final a = _Plan(100);
      final b = _Plan(200)..gate = Completer<void>();
      final c = _Plan(300);
      final core = _owner(a);
      addTearDown(core.close);
      final seen = <int>[];
      final subscription = core.states.listen((s) {
        if (s is DesktopCoreRunning) seen.add(s.session.pid);
      });
      addTearDown(subscription.cancel);
      await core.start();
      final first = core.applyConfiguration(b.plan);
      await _until(() => b.leases.isNotEmpty);
      final latest = core.applyConfiguration(c.plan);
      b.gate!.complete();
      expect((await first).outcome, CoreLifecycleOutcome.superseded);
      expect((await latest).session!.pid, 300);
      expect(b.leases.single.stopCount, 1);
      expect(seen, isNot(contains(200)));
      expect(core.committedPlan, same(c.plan));
    },
  );

  test(
    'start preempts replacement using the committed configuration',
    () async {
      final a = _Plan(100);
      final b = _Plan(200)..gate = Completer<void>();
      final core = _owner(a);
      addTearDown(core.close);
      await core.start();
      final first = core.applyConfiguration(b.plan);
      await _until(() => b.leases.isNotEmpty);
      final latest = core.start();
      b.gate!.complete();
      expect((await first).outcome, CoreLifecycleOutcome.superseded);
      expect((await latest).session!.pid, 101);
      expect(core.committedPlan, same(a.plan));
    },
  );

  test('an unconfirmed old exit blocks replacement process creation', () async {
    final a = _Plan(100);
    final b = _Plan(200);
    final core = _owner(a);
    addTearDown(core.close);
    await core.start();
    a.leases.single.stopResult = const CoreProcessStopResult(
      stopped: false,
      exitConfirmed: false,
    );
    await expectLater(
      core.applyConfiguration(b.plan),
      throwsA(isA<DesktopCoreFailure>()),
    );
    expect(b.leases, isEmpty);
    expect(a.leases.length, 1);
    a.leases.single.stopResult = const CoreProcessStopResult(
      stopped: true,
      exitConfirmed: true,
    );
    await core.applyConfiguration(b.plan);
    expect(core.committedPlan, same(b.plan));
  });

  test('failed candidate cleanup must confirm exit before recovery', () async {
    final a = _Plan(100);
    final b = _Plan(200)..connect = false;
    final core = _owner(a);
    addTearDown(core.close);
    await core.start();
    final changed = core.applyConfiguration(b.plan);
    final failure = expectLater(changed, throwsA(isA<DesktopCoreFailure>()));
    await _until(() => b.leases.isNotEmpty);
    b.leases.single.stopResult = const CoreProcessStopResult(
      stopped: false,
      exitConfirmed: false,
    );
    b.transports.last.fail(StateError('candidate rejected'));
    await failure;
    expect(a.leases.length, 1);
    expect(core.state, isA<DesktopCoreFailed>());
    b.leases.single.stopResult = const CoreProcessStopResult(
      stopped: true,
      exitConfirmed: true,
    );
    await core.stop();
    expect(core.state, isA<DesktopCoreIdle>());
  });

  test(
    'idle activation failure does not start a previously stopped configuration',
    () async {
      final a = _Plan(100);
      final b = _Plan(200)..startError = StateError('rejected');
      final core = _owner(a);
      addTearDown(core.close);
      await expectLater(
        core.applyConfiguration(b.plan),
        throwsA(isA<DesktopCoreFailure>()),
      );
      expect(a.leases, isEmpty);
      expect(core.state, isA<DesktopCoreFailed>());
      expect(core.committedPlan, same(a.plan));
    },
  );

  test(
    'coalesced candidate failures recover once and fail both requests',
    () async {
      final a = _Plan(100);
      final b = _Plan(200)
        ..gate = Completer<void>()
        ..startError = StateError('rejected');
      final core = _owner(a);
      addTearDown(core.close);
      await core.start();
      final first = core.applyConfiguration(b.plan);
      final firstError = expectLater(first, throwsA(isA<DesktopCoreFailure>()));
      await _until(() => b.leases.isNotEmpty);
      final second = core.applyConfiguration(b.plan);
      final secondError = expectLater(
        second,
        throwsA(isA<DesktopCoreFailure>()),
      );
      b.gate!.complete();
      await Future.wait([firstError, secondError]);
      expect(b.leases.length, 1);
      expect(a.leases.length, 2);
      expect(core.state, isA<DesktopCoreRunning>());
    },
  );

  test(
    'a newer failing candidate still restores the last working plan',
    () async {
      final a = _Plan(100);
      final b = _Plan(200)..gate = Completer<void>();
      final c = _Plan(300)..startError = StateError('rejected');
      final core = _owner(a);
      addTearDown(core.close);
      await core.start();
      final first = core.applyConfiguration(b.plan);
      await _until(() => b.leases.isNotEmpty);
      final latest = core.applyConfiguration(c.plan);
      final failure = expectLater(latest, throwsA(isA<DesktopCoreFailure>()));
      b.gate!.complete();
      await failure;
      await first;
      expect(a.leases.length, 2);
      expect(core.state, isA<DesktopCoreRunning>());
      expect(core.committedPlan, same(a.plan));
    },
  );

  test(
    'stop during recovery prevents the old configuration from returning',
    () async {
      final a = _Plan(100);
      final b = _Plan(200)..startError = StateError('rejected');
      final core = _owner(a);
      addTearDown(core.close);
      await core.start();
      a.gate = Completer<void>();
      final changed = core.applyConfiguration(b.plan);
      await _until(() => a.leases.length == 2);
      final stopped = core.stop();
      a.gate!.complete();
      expect((await changed).outcome, CoreLifecycleOutcome.superseded);
      await stopped;
      expect(a.leases.last.stopCount, 1);
      expect(core.state, isA<DesktopCoreIdle>());
    },
  );

  test(
    'rollback failure remains failed and can be explicitly retried',
    () async {
      final a = _Plan(100);
      final b = _Plan(200)..startError = StateError('rejected');
      final core = _owner(a);
      addTearDown(core.close);
      await core.start();
      a.startError = StateError('old port unavailable');
      await expectLater(
        core.applyConfiguration(b.plan),
        throwsA(isA<DesktopCoreFailure>()),
      );
      expect(core.state, isA<DesktopCoreFailed>());
      expect(core.committedPlan, same(a.plan));
      a.startError = null;
      await core.start();
      expect(core.state, isA<DesktopCoreRunning>());
    },
  );
}

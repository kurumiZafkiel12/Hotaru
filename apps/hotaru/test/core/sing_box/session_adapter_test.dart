import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/sing_box/session_adapter.dart';
import 'package:mocktail/mocktail.dart';

import '../desktop/fakes.dart';

final class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

final class _Adapter extends Mock implements CoreAdapter {}

DesktopCoreRunning _running(String id) => DesktopCoreRunning(
  DesktopCoreSession(
    sessionId: id,
    connectionGeneration: 1,
    lease: FakeProcessLease(
      owner: CoreProcessOwner.direct,
      pid: 4321,
      sessionId: id,
    ),
  ),
);

void main() {
  late _Lifecycle lifecycle;
  late _Adapter first;
  late _Adapter second;
  late StreamController<DesktopCoreState> events;
  late DesktopCoreState state;
  late SessionCoreAdapter adapter;
  var created = 0;

  setUp(() {
    lifecycle = _Lifecycle();
    first = _Adapter();
    second = _Adapter();
    events = StreamController<DesktopCoreState>.broadcast();
    state = _running('first');
    created = 0;
    when(() => lifecycle.state).thenAnswer((_) => state);
    when(() => lifecycle.states).thenAnswer((_) => events.stream);
    for (final client in [first, second]) {
      when(() => client.outbounds()).thenAnswer((_) async => const []);
      when(() => client.close()).thenAnswer((_) async {});
    }
    adapter = SessionCoreAdapter(
      lifecycle: lifecycle,
      factory: () => ++created == 1 ? first : second,
    );
  });

  tearDown(() async {
    await adapter.close();
    await events.close();
  });

  test(
    'idle operations neither create an API client nor start the process',
    () async {
      state = const DesktopCoreIdle();
      await expectLater(
        adapter.outbounds(),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'core_not_running',
          ),
        ),
      );
      expect(created, 0);
      verifyNever(() => lifecycle.start());
    },
  );

  test(
    'a response from a previous session is never accepted after restart',
    () async {
      final response = Completer<List<CoreOutbound>>();
      when(() => first.outbounds()).thenAnswer((_) => response.future);
      final stale = adapter.outbounds();
      state = _running('second');
      events.add(state);
      await pumpEventQueue();
      final rejected = expectLater(
        stale,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      response.complete(const []);
      await rejected;
      await adapter.outbounds();
      expect(created, 2);
      verify(() => first.close()).called(1);
      verify(() => second.outbounds()).called(1);
    },
  );

  test(
    'old transport errors become session changes rather than node failures',
    () async {
      final response = Completer<List<CoreOutbound>>();
      when(() => first.outbounds()).thenAnswer((_) => response.future);
      final stale = adapter.outbounds();
      state = const DesktopCoreIdle();
      final rejected = expectLater(
        stale,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      response.completeError(const CoreAdapterException('transport'));
      await rejected;
    },
  );

  test(
    'errors within the same live session retain their actual cause',
    () async {
      when(
        () => first.outbounds(),
      ).thenThrow(const CoreAdapterException('http', status: 503));
      await expectLater(
        adapter.outbounds(),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.status,
            'status',
            503,
          ),
        ),
      );
    },
  );

  test(
    'queued old state events cannot invalidate the current live client',
    () async {
      state = _running('second');
      await adapter.outbounds();
      events.add(_running('first'));
      await pumpEventQueue();
      await adapter.outbounds();
      expect(created, 1);
      verifyNever(() => first.close());
    },
  );

  test(
    'close waits for client cleanup and is terminal and idempotent',
    () async {
      final cleanup = Completer<void>();
      when(() => first.close()).thenAnswer((_) => cleanup.future);
      await adapter.outbounds();
      final closing = adapter.close();
      expect(identical(closing, adapter.close()), isTrue);
      cleanup.complete();
      await closing;
      await expectLater(
        adapter.outbounds(),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'closed',
          ),
        ),
      );
      verify(() => first.close()).called(1);
    },
  );
}

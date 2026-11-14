import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/logs.dart';
import 'package:hotaru/core/maintenance.dart';
import 'package:hotaru/core/config/probe_listener.dart';
import 'package:hotaru/core/outbound_http.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'support/telemetry_fixture.dart';
import 'package:hotaru/core/sing_box/outbound_http.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/sing_box/session_adapter.dart';
import 'package:mocktail/mocktail.dart';

import '../desktop/fakes.dart';

final class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

class _Adapter extends Mock implements CoreAdapter {}

final class _LoggingAdapter extends _Adapter implements CoreLogSource {}

final class _MaintenanceAdapter extends Mock
    implements CoreAdapter, CoreRuntimeMaintenance, CoreConnectionMaintenance {}

final class _TelemetryAdapter extends Mock
    implements CoreAdapter, CoreTelemetry {}

final class _PathAdapter extends Mock
    implements CoreAdapter, CoreTelemetry, CoreConnectionPathTelemetry {}

final class _RoutingAdapter extends Mock
    implements CoreAdapter, CoreRoutingModes {}

final class _HttpAdapter extends Mock implements CoreAdapter, CoreOutboundHttp {
  final transport = SingBoxOutboundHttp(
    listener: const CoreProbeListenerSpec(
      port: 17891,
      secret: 'fixture-only-12345678901234567890123456789',
    ),
    outbounds: ['node'],
  );

  @override
  Future<T> withOutboundClient<T>(
    String outbound,
    Future<T> Function(HttpClient client) action, {
    Duration timeout = const Duration(minutes: 2),
  }) => transport.withOutboundClient(outbound, action, timeout: timeout);

  @override
  Future<void> close() async => transport.close();
}

final class _FactoryAdapter extends _HttpAdapter
    implements CoreOutboundHttpClients {
  @override
  Future<T> withOutboundClients<T>(
    String outbound,
    Future<T> Function(CoreOutboundClients clients) action, {
    Duration timeout = const Duration(minutes: 2),
  }) => transport.withOutboundClients(outbound, action, timeout: timeout);
}

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
    'unsubscribed logs neither instantiate a client nor start a core',
    () async {
      adapter.logs();
      await Future<void>.delayed(Duration.zero);
      expect(created, 0);
      state = const DesktopCoreIdle();
      await expectLater(
        adapter.logs().toList(),
        throwsA(isA<CoreAdapterException>()),
      );
      expect(created, 0);
      verifyNever(() => lifecycle.start());
    },
  );

  test(
    'log observations from a replaced session never reach the new session',
    () async {
      final source = StreamController<CoreLogMessage>.broadcast(sync: true);
      final logging = _LoggingAdapter();
      first = logging;
      when(() => logging.close()).thenAnswer((_) async {});
      when(() => logging.logs()).thenAnswer((_) => source.stream);
      final messages = <CoreLogMessage>[];
      final errors = <Object>[];
      final subscription = adapter.logs().listen(
        messages.add,
        onError: errors.add,
      );
      await Future<void>.delayed(Duration.zero);
      source.add(const CoreLogMessage(level: 'info', payload: 'first session'));
      await Future<void>.delayed(Duration.zero);
      expect(messages.single.payload, 'first session');
      state = _running('second');
      events.add(state);
      await Future<void>.delayed(Duration.zero);
      source.add(const CoreLogMessage(level: 'error', payload: 'stale'));
      await Future<void>.delayed(Duration.zero);
      expect(messages, hasLength(1));
      expect(errors, isEmpty);
      await subscription.cancel();
      await source.close();
    },
  );

  test(
    'missing maintenance support fails before dispatch and never closes unrelated connections',
    () async {
      await expectLater(
        adapter.collectMemory(),
        throwsA(isA<CoreAdapterException>()),
      );
      await expectLater(
        adapter.clearDnsCache(),
        throwsA(isA<CoreAdapterException>()),
      );
      verifyNever(() => first.closeConnection(any()));
    },
  );

  test(
    'maintenance rejects an acknowledgement from a replaced session',
    () async {
      final native = _MaintenanceAdapter();
      when(() => native.close()).thenAnswer((_) async {});
      when(() => native.collectMemory()).thenAnswer((_) async {});
      when(() => native.clearDnsCache()).thenAnswer((_) async {});
      when(() => native.closeConnections()).thenAnswer((_) async {});
      final pending = Completer<void>();
      when(
        () => native.resetDnsConnections(),
      ).thenAnswer((_) => pending.future);
      final subject = SessionCoreAdapter(
        lifecycle: lifecycle,
        factory: () => native,
      );
      addTearDown(subject.close);
      await subject.collectMemory();
      await subject.clearDnsCache();
      await subject.closeConnections();
      final read = subject.resetDnsConnections();
      final checked = expectLater(
        read,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      state = _running('second');
      events.add(state);
      pending.complete();
      await checked;
    },
  );

  test('an adapter without node HTTP support refuses the callback', () async {
    var invoked = false;
    await expectLater(
      adapter.withOutboundClient('node', (_) async {
        invoked = true;
        return 42;
      }),
      throwsA(
        isA<CoreAdapterException>().having(
          (e) => e.code,
          'code',
          'outbound_http_unavailable',
        ),
      ),
    );
    expect(invoked, isFalse);
  });

  test(
    'a retained factory cannot create clients after its session changes',
    () async {
      final inner = _FactoryAdapter();
      final scoped = SessionCoreAdapter(
        lifecycle: lifecycle,
        factory: () => inner,
      );
      addTearDown(scoped.close);
      final entered = Completer<CoreOutboundClients>();
      final release = Completer<int>();
      final call = scoped.withOutboundClients('node', (clients) async {
        entered.complete(clients);
        return release.future;
      });
      final result = expectLater(
        call,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      final clients = await entered.future;
      state = _running('new');
      expect(
        clients.createClient,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      release.complete(1);
      await result;
    },
  );

  test('missing mode capability cannot pretend a mode was applied', () async {
    await expectLater(
      adapter.setRoutingMode(CoreRoutingMode.global),
      throwsA(
        isA<CoreAdapterException>().having(
          (error) => error.code,
          'code',
          'routing_modes_unavailable',
        ),
      ),
    );
  });

  test(
    'a late mode acknowledgement from a replaced session is rejected',
    () async {
      final inner = _RoutingAdapter();
      final pending = Completer<void>();
      when(
        () => inner.setRoutingMode(CoreRoutingMode.direct),
      ).thenAnswer((_) => pending.future);
      when(() => inner.close()).thenAnswer((_) async {});
      final scoped = SessionCoreAdapter(
        lifecycle: lifecycle,
        factory: () => inner,
      );
      addTearDown(scoped.close);
      final change = scoped.setRoutingMode(CoreRoutingMode.direct);
      final checked = expectLater(
        change,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      state = _running('replacement');
      pending.complete();
      await checked;
    },
  );

  test(
    'session replacement closes the probe client and rejects its late result',
    () async {
      final underlying = _HttpAdapter();
      final scoped = SessionCoreAdapter(
        lifecycle: lifecycle,
        factory: () => underlying,
      );
      addTearDown(scoped.close);
      final pending = Completer<int>();
      HttpClient? client;
      final result = scoped.withOutboundClient('node', (current) {
        client = current;
        return pending.future;
      });
      state = _running('replacement');
      events.add(state);
      await pumpEventQueue();
      expect(
        () => client!.getUrl(Uri.parse('http://127.0.0.1/')),
        throwsStateError,
      );
      final rejected = expectLater(
        result,
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'session_changed',
          ),
        ),
      );
      pending.complete(42);
      await rejected;
    },
  );

  test(
    'session wrapper forwards optional path snapshots without replacing ordinary counters',
    () async {
      final native = _PathAdapter();
      when(() => native.close()).thenAnswer((_) async {});
      when(() => native.telemetry()).thenAnswer(
        (_) async =>
            CoreTelemetrySnapshot.fromJson(telemetryFixture(upload: 1)),
      );
      final pending = Completer<CoreTelemetrySnapshot>();
      when(() => native.pathTelemetry()).thenAnswer((_) => pending.future);
      final scoped = SessionCoreAdapter(
        lifecycle: lifecycle,
        factory: () => native,
      );
      addTearDown(scoped.close);
      expect((await scoped.telemetry()).uploadTotal, 1);
      final result = scoped.pathTelemetry();
      final rejected = expectLater(
        result,
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'session_changed',
          ),
        ),
      );
      state = _running('replacement');
      events.add(state);
      await pumpEventQueue();
      pending.complete(
        CoreTelemetrySnapshot.fromJson(telemetryFixture(upload: 9)),
      );
      await rejected;
      verify(() => native.pathTelemetry()).called(1);
      verify(() => native.telemetry()).called(1);
    },
  );

  test(
    'observed counters from an old session cannot be credited to its replacement',
    () async {
      final underlying = _TelemetryAdapter();
      final pending = Completer<CoreTelemetrySnapshot>();
      when(() => underlying.telemetry()).thenAnswer((_) => pending.future);
      when(() => underlying.close()).thenAnswer((_) async {});
      final scoped = SessionCoreAdapter(
        lifecycle: lifecycle,
        factory: () => underlying,
      );
      addTearDown(scoped.close);
      final result = scoped.telemetry();
      state = _running('replacement');
      events.add(state);
      await pumpEventQueue();
      final rejected = expectLater(
        result,
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'session_changed',
          ),
        ),
      );
      pending.complete(
        CoreTelemetrySnapshot.fromJson(telemetryFixture(upload: 123456)),
      );
      await rejected;
      verify(() => underlying.close()).called(1);
    },
  );

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

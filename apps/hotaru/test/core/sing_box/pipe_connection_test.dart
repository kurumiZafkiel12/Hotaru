import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/adapter.dart';
import 'support/telemetry_fixture.dart';
import 'package:hotaru/core/desktop/transport.dart';
import 'package:hotaru/core/sing_box/pipe_connection.dart';
import 'package:hotaru/core/sing_box/bootstrap.dart';

final class _Pipe implements DesktopCoreTransport {
  final _events = StreamController<DesktopTransportEvent>.broadcast();
  final _frames = StreamController<Uint8List>.broadcast();
  final sent = <List<int>>[];
  final configured = Completer<void>();
  void Function()? onStop;
  void Function(Map<String, dynamic>)? onRequest;
  @override
  DesktopTransportState state = DesktopTransportState.idle;
  @override
  String get address => r'\\.\pipe\HotaruCore_0123456789abcdef0123456789abcdef';
  @override
  Stream<DesktopTransportEvent> get events => _events.stream;
  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> open() async => state = DesktopTransportState.ready;
  void connect(int pid) =>
      _events.add(TransportConnected(pid: pid, generation: 1));
  void disconnect() => _events.add(const TransportDisconnected(1));
  void host(String event, {bool clean = false, int pid = 42}) {
    _frames.add(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocol': 'hotaru-stdio-v1',
            'event': event,
            'pid': pid,
            if (clean) 'clean': true,
          }),
        ),
      ),
    );
  }

  void telemetry(
    int id, {
    Map<String, dynamic>? data,
    String? error,
    int pid = 42,
  }) {
    _frames.add(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocol': 'hotaru-stdio-v1',
            'event': 'telemetry',
            'pid': pid,
            'request_id': id,
            'data': ?data,
            'error': ?error,
          }),
        ),
      ),
    );
  }

  @override
  void send(List<int> frame) {
    if (state == DesktopTransportState.closed) throw StateError('Closed');
    sent.add(frame);
    if (utf8.decode(frame) == 'stop\n') {
      onStop?.call();
    } else if (!configured.isCompleted) {
      configured.complete();
    } else {
      onRequest?.call(jsonDecode(utf8.decode(frame)) as Map<String, dynamic>);
    }
  }

  @override
  Future<TransportConnected> waitUntilConnected(Duration timeout) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {
    if (state == DesktopTransportState.closed) return;
    state = DesktopTransportState.closed;
    await _events.close();
    await _frames.close();
  }
}

final class _Controller
    implements DesktopCoreConnection, DesktopCoreProcessObserver {
  final _events = StreamController<DesktopTransportEvent>.broadcast();
  int observed = 0;
  int peerPid = 42;
  @override
  String get address => 'http://127.0.0.1:19090';
  @override
  DesktopTransportState state = DesktopTransportState.idle;
  @override
  Stream<DesktopTransportEvent> get events => _events.stream;
  @override
  Future<void> open() async => state = DesktopTransportState.ready;
  @override
  void observeProcess(CoreProcessLease process) {
    observed++;
    _events.add(TransportConnected(pid: peerPid, generation: 1));
  }

  @override
  Future<TransportConnected> waitUntilConnected(Duration timeout) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {
    state = DesktopTransportState.closed;
    await _events.close();
  }
}

final class _Lease implements CoreProcessLease {
  int stops = 0;
  @override
  String get sessionId => 'fixture';
  @override
  int get pid => 42;
  @override
  CoreProcessOwner get owner => CoreProcessOwner.helper;
  @override
  Future<CoreProcessStopResult> stop(Duration timeout) async {
    stops++;
    return const CoreProcessStopResult(stopped: true, exitConfirmed: true);
  }
}

void main() {
  late _Pipe pipe;
  late _Controller controller;
  late _Lease process;
  late SingBoxPipeConnection connection;
  late SingBoxPipeLease lease;

  setUp(() async {
    pipe = _Pipe();
    controller = _Controller();
    process = _Lease();
    connection = SingBoxPipeConnection(
      pipe: pipe,
      controller: controller,
      bootstrap: await SingBoxBootstrap.prepare(
        '{"experimental":{"clash_api":{"secret":"fixture"}}}',
      ),
    );
    lease = SingBoxPipeLease(process: process, connection: connection);
    await connection.open();
  });
  tearDown(() => connection.close());

  Future<void> bootstrap() async {
    connection.observeProcess(lease);
    pipe.connect(process.pid);
    await pipe.configured.future.timeout(const Duration(seconds: 2));
  }

  Future<void> connect() async {
    await bootstrap();
    pipe.host('ready');
    await connection.waitUntilConnected(const Duration(seconds: 2));
  }

  test(
    'telemetry before an owned connected session sends no request',
    () async {
      await expectLater(
        connection.telemetry(),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'core_not_running',
          ),
        ),
      );
      expect(pipe.sent, isEmpty);
    },
  );

  test(
    'concurrent read-only replies are matched by request ID, including reverse arrival',
    () async {
      await connect();
      final ids = <int>[];
      pipe.onRequest = (request) {
        expect(request['method'], 'telemetry');
        ids.add(request['id'] as int);
        if (ids.length == 2) {
          pipe.telemetry(ids[1], data: telemetryFixture(upload: 2));
          pipe.telemetry(ids[0], data: telemetryFixture(upload: 1));
        }
      };
      final results = await Future.wait([
        connection.telemetry(),
        connection.telemetry(),
      ]);
      expect(results.map((value) => value.uploadTotal), [1, 2]);
      expect(connection.state, DesktopTransportState.connected);
      expect(pipe.sent, hasLength(3));
    },
  );

  test(
    'unavailable native telemetry is explicit and does not kill the core',
    () async {
      await connect();
      pipe.onRequest = (request) =>
          pipe.telemetry(request['id'] as int, error: 'telemetry_unavailable');
      await expectLater(
        connection.telemetry(),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'telemetry_unavailable',
          ),
        ),
      );
      expect(connection.state, DesktopTransportState.connected);
    },
  );

  test(
    'wrong reply PID cancels pending data instead of accepting another core',
    () async {
      await connect();
      pipe.onRequest = (request) => pipe.telemetry(
        request['id'] as int,
        data: telemetryFixture(),
        pid: 99,
      );
      await expectLater(
        connection.telemetry(),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'session_changed',
          ),
        ),
      );
      expect(connection.state, DesktopTransportState.failed);
    },
  );

  test(
    'stop cancels telemetry but queued cleanup acknowledgement still releases the lease',
    () async {
      await connect();
      final pending = expectLater(
        connection.telemetry(),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'session_changed',
          ),
        ),
      );
      pipe.onStop = () {
        pipe.host('stopped', clean: true);
        pipe.disconnect();
      };
      expect(
        (await lease.stop(const Duration(seconds: 2))).exitConfirmed,
        isTrue,
      );
      await pending;
      expect(process.stops, 1);
    },
  );

  test(
    'controller failure still consumes a valid host cleanup acknowledgement',
    () async {
      await connect();
      controller._events.add(
        TransportFailed(StateError('Controller lost'), StackTrace.current),
      );
      await pumpEventQueue();
      expect(connection.state, DesktopTransportState.failed);
      pipe.onStop = () {
        pipe.host('stopped', clean: true);
        pipe.disconnect();
      };
      expect(
        (await lease.stop(const Duration(seconds: 2))).exitConfirmed,
        isTrue,
      );
    },
  );

  test(
    'control data after stopped cannot preserve a clean acknowledgement',
    () async {
      await connect();
      var id = 0;
      pipe.onRequest = (request) {
        id = request['id'] as int;
        pipe.telemetry(id, data: telemetryFixture());
      };
      await connection.telemetry();
      pipe.onStop = () {
        pipe.host('stopped', clean: true);
        pipe.telemetry(id, data: telemetryFixture());
        pipe.disconnect();
      };
      expect(
        (await lease.stop(const Duration(seconds: 2))).exitConfirmed,
        isFalse,
      );
      expect(process.stops, 0);
    },
  );

  test(
    'does not send credentials to a peer before acquiring its lease',
    () async {
      pipe.connect(process.pid);
      await Future<void>.delayed(Duration.zero);
      expect(pipe.sent, isEmpty);
      connection.observeProcess(lease);
      await pipe.configured.future.timeout(const Duration(seconds: 2));
      final request = jsonDecode(utf8.decode(pipe.sent.single));
      expect(request['protocol'], 'hotaru-bootstrap-v1');
      expect(controller.observed, 0);
      final ready = connection.waitUntilConnected(const Duration(seconds: 2));
      pipe.host('ready');
      expect((await ready).pid, 42);
      expect(controller.observed, 1);
    },
  );

  test('wrong pipe PID fails without sending the configuration', () async {
    final failed = expectLater(
      connection.waitUntilConnected(const Duration(seconds: 1)),
      throwsStateError,
    );
    connection.observeProcess(lease);
    pipe.connect(99);
    await failed;
    expect(pipe.sent, isEmpty);
    expect(controller.observed, 0);
  });

  test(
    'requires clean acknowledgement and pipe EOF before releasing Helper',
    () async {
      await bootstrap();
      pipe.host('ready');
      await connection.waitUntilConnected(const Duration(seconds: 1));
      pipe.onStop = () => pipe.host('stopped', clean: true);
      final stopping = lease.stop(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(process.stops, 0);
      pipe.disconnect();
      expect((await stopping).exitConfirmed, isTrue);
      await lease.stop(const Duration(seconds: 1));
      expect(process.stops, 1);
    },
  );

  test(
    'timeout retains ownership and a later clean stop can be retried',
    () async {
      await bootstrap();
      pipe.host('ready');
      await connection.waitUntilConnected(const Duration(seconds: 1));
      final first = await lease.stop(const Duration(milliseconds: 10));
      expect(first.exitConfirmed, isFalse);
      expect(process.stops, 0);
      pipe.onStop = () {
        pipe.host('stopped', clean: true);
        pipe.disconnect();
      };
      expect(
        (await lease.stop(const Duration(seconds: 1))).exitConfirmed,
        isTrue,
      );
      expect(process.stops, 1);
    },
  );

  test(
    'unclean stop or wrong event PID cannot release the Helper lease',
    () async {
      await bootstrap();
      pipe.host('ready');
      await connection.waitUntilConnected(const Duration(seconds: 1));
      pipe.onStop = () {
        pipe.host('stopped', pid: 99, clean: true);
        pipe.disconnect();
      };
      expect(
        (await lease.stop(const Duration(seconds: 1))).exitConfirmed,
        isFalse,
      );
      expect(process.stops, 0);
    },
  );

  test('disconnect alone does not acknowledge cleanup', () async {
    await bootstrap();
    pipe.host('ready');
    await connection.waitUntilConnected(const Duration(seconds: 1));
    pipe.onStop = pipe.disconnect;
    expect(
      (await lease.stop(const Duration(seconds: 1))).exitConfirmed,
      isFalse,
    );
    expect(process.stops, 0);
  });

  test('cancelled startup cannot send a prepared bootstrap', () async {
    connection.observeProcess(lease);
    pipe.connect(42);
    expect(
      (await lease.stop(const Duration(seconds: 1))).exitConfirmed,
      isTrue,
    );
    await connection.close();
    expect(pipe.sent, isEmpty);
    expect(process.stops, 1);
    expect(controller.observed, 0);
  });

  test('controller PID must match the already verified pipe peer', () async {
    controller.peerPid = 99;
    await bootstrap();
    final failed = expectLater(
      connection.waitUntilConnected(const Duration(seconds: 1)),
      throwsStateError,
    );
    pipe.host('ready');
    await failed;
  });

  test('a second peer cannot reuse the same bootstrap session', () async {
    await bootstrap();
    final failed = expectLater(
      connection.waitUntilConnected(const Duration(seconds: 1)),
      throwsStateError,
    );
    pipe.connect(42);
    await failed;
    expect(pipe.sent.length, 1);
  });
}

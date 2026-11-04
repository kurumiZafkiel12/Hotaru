import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/desktop/transport.dart';
import 'package:hotaru/core/sing_box/pipe_connection.dart';

final class _Pipe implements DesktopCoreTransport {
  final _events = StreamController<DesktopTransportEvent>.broadcast();
  final _frames = StreamController<Uint8List>.broadcast();
  final sent = <List<int>>[];
  final configured = Completer<void>();
  void Function()? onStop;
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

  @override
  void send(List<int> frame) {
    if (state == DesktopTransportState.closed) throw StateError('Closed');
    sent.add(frame);
    if (utf8.decode(frame) == 'stop\n') {
      onStop?.call();
    } else if (!configured.isCompleted) {
      configured.complete();
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
      compiledConfig: '{"experimental":{"clash_api":{"secret":"fixture"}}}',
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

  test('cancelled startup cannot send a late isolate bootstrap', () async {
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

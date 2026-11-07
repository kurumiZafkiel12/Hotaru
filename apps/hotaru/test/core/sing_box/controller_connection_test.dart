import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/desktop/connection.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/sing_box/controller_connection.dart';

void main() {
  late HttpServer server;
  late Uri endpoint;
  late _OwnedProcess process;
  SingBoxControllerConnection? connection;
  var requests = 0;
  var status = 200;
  var version = 'sing-box 1.14.4';

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    process = _OwnedProcess();
    requests = 0;
    status = 200;
    version = 'sing-box 1.14.4';
    server.listen((request) async {
      requests++;
      expect(request.headers.value('authorization'), 'Bearer fixture-secret');
      request.response.statusCode = status;
      request.response.write(jsonEncode({'version': version}));
      await request.response.close();
    });
  });

  tearDown(() async {
    await connection?.close();
    connection = null;
    await process.stop(const Duration(seconds: 1));
    await server.close(force: true);
  });

  SingBoxControllerConnection create({
    Future<int?> Function()? peerPid,
    bool verify = true,
  }) {
    return connection = SingBoxControllerConnection(
      endpoint: endpoint,
      secret: 'fixture-secret',
      verifyPeerPid: verify,
      peerPid: peerPid ?? (() async => process.pid),
      interval: const Duration(milliseconds: 10),
    );
  }

  test(
    'does not attach to a valid controller before an owned process exists',
    () async {
      final current = create();
      await current.open();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requests, 0);
      final connected = current.waitUntilConnected(const Duration(seconds: 2));
      current.observeProcess(process);
      expect((await connected).pid, process.pid);
    },
  );

  test('rejects a different listener PID before sending credentials', () async {
    final current = create(peerPid: () async => process.pid + 1);
    await current.open();
    final rejected = expectLater(
      current.waitUntilConnected(const Duration(seconds: 2)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('PID'),
        ),
      ),
    );
    current.observeProcess(process);
    await rejected;
    expect(current.state, DesktopTransportState.failed);
    expect(requests, 0);
  });

  test(
    'missing listener ownership never sends an authenticated request',
    () async {
      var checks = 0;
      final checked = Completer<void>();
      final current = create(
        peerPid: () async {
          if (++checks == 2) checked.complete();
          return null;
        },
      );
      await current.open();
      current.observeProcess(process);
      await checked.future.timeout(const Duration(seconds: 2));
      expect(requests, 0);
      expect(current.state, DesktopTransportState.ready);
    },
  );

  test(
    'observes owned exit even when the HTTP controller still responds',
    () async {
      final current = create();
      await current.open();
      final connected = current.waitUntilConnected(const Duration(seconds: 2));
      current.observeProcess(process);
      await connected;
      final failure = current.events.firstWhere(
        (event) => event is TransportFailed,
      );
      await process.stop(const Duration(seconds: 1));
      expect(
        (await failure as TransportFailed).error.toString(),
        contains('exited'),
      );
      expect(current.state, DesktopTransportState.failed);
    },
  );

  test(
    'close during listener verification cannot publish a late connection',
    () async {
      final lookupStarted = Completer<void>();
      final lookupResult = Completer<int?>();
      final current = create(
        peerPid: () {
          lookupStarted.complete();
          return lookupResult.future;
        },
      );
      final connected = <TransportConnected>[];
      final subscription = current.events.listen((event) {
        if (event is TransportConnected) connected.add(event);
      });
      await current.open();
      current.observeProcess(process);
      await lookupStarted.future;
      final closing = current.close();
      lookupResult.complete(process.pid);
      await closing;
      expect(connected, isEmpty);
      expect(current.state, DesktopTransportState.closed);
      expect(requests, 0);
      await subscription.cancel();
    },
  );

  test('mismatched core version never becomes ready', () async {
    version = 'Mihomo 1.19';
    final current = create();
    await current.open();
    final rejected = expectLater(
      current.waitUntilConnected(const Duration(seconds: 2)),
      throwsStateError,
    );
    current.observeProcess(process);
    await rejected;
    expect(current.state, DesktopTransportState.failed);
  });

  test(
    'the owned host must finish startup before the controller is queried',
    () async {
      final starting = _StartingProcess();
      process = starting;
      final current = create();
      await current.open();
      current.observeProcess(starting);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requests, 0);
      final connected = current.waitUntilConnected(const Duration(seconds: 2));
      starting.initialized.complete();
      expect((await connected).pid, starting.pid);
    },
  );

  test(
    'persistent controller failure ends the connection rather than claiming running',
    () async {
      final current = create();
      await current.open();
      final connected = current.waitUntilConnected(const Duration(seconds: 2));
      current.observeProcess(process);
      await connected;
      final failure = current.events
          .firstWhere((event) => event is TransportFailed)
          .timeout(const Duration(seconds: 2));
      status = 503;
      await failure;
      expect(current.state, DesktopTransportState.failed);
    },
  );
}

final class _OwnedProcess implements CoreProcessExitSource {
  final Completer<int> exited = Completer<int>();

  @override
  int get pid => 4321;
  @override
  String get sessionId => 'fixture-session';
  @override
  CoreProcessOwner get owner => CoreProcessOwner.direct;
  @override
  Future<int> get exitCode => exited.future;

  @override
  Future<CoreProcessStopResult> stop(Duration timeout) async {
    if (!exited.isCompleted) exited.complete(1);
    return const CoreProcessStopResult(stopped: true, exitConfirmed: true);
  }
}

final class _StartingProcess extends _OwnedProcess
    implements CoreProcessReadySource {
  final Completer<void> initialized = Completer<void>();
  @override
  Future<void> get ready => initialized.future;
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/routed_http.dart';
import 'package:hotaru/core/sing_box/http_probe.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/models/core.dart';

import 'support/telemetry_fixture.dart';

class _Transport implements CoreRoutedHttp {
  final int port;
  final outbounds = <String?>[];
  int closed = 0;
  _Transport(this.port);
  @override
  Future<T> withRoutedClient<T>(
    Future<T> Function(HttpClient) action, {
    String? outbound,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    outbounds.add(outbound);
    final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      return await action(client).timeout(timeout);
    } finally {
      client.close(force: true);
      closed++;
    }
  }
}

void main() {
  late HttpServer gateway;
  late _Transport transport;
  late SingBoxHttpProbe probe;
  final observations = <Map<String, dynamic>>[];
  final received = <HttpHeaders>[];
  final hold = Completer<void>();
  void Function(Map<String, dynamic>)? alter;
  var duplicate = false;

  setUp(() async {
    observations.clear();
    received.clear();
    alter = null;
    duplicate = false;
    gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => gateway.close(force: true));
    gateway.listen((request) async {
      received.add(request.headers);
      final observed = observedConnectionFixture()
        ..['id'] = 'request-${received.length}'
        ..['created_at'] = DateTime.now().toUtc().toIso8601String()
        ..['source_ip'] = request.connectionInfo!.remoteAddress.address
        ..['source_port'] = request.connectionInfo!.remotePort
        ..['destination_port'] = request.uri.port
        ..['host'] = request.uri.host
        ..['inbound'] = 'mixed'
        ..['network'] = 'tcp'
        ..['chain'] = ['B', 'Selected']
        ..['outbound'] = 'B'
        ..['rule'] = 'final';
      alter?.call(observed);
      observations.add(observed);
      if (duplicate) observations.add({...observed, 'id': 'ambiguous'});
      if (request.uri.path == '/slow') return;
      if (request.uri.path == '/held') await hold.future;
      if (request.uri.path == '/same') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/final');
      } else if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('location', 'http://second.invalid/final');
      } else {
        request.response.statusCode = 403;
        request.response.write('abcdefghijk');
      }
      unawaited(request.response.close());
    });
    transport = _Transport(gateway.port);
    probe = SingBoxHttpProbe(
      transport: transport,
      observe: () async => CoreTelemetrySnapshot.fromJson(
        telemetryFixture()
          ..['active'] = List.of(observations)
          ..['closed'] = [],
      ),
    );
  });

  ProbeParams params({
    String path = '/',
    String proxyName = '',
    int maxBody = 4,
    int timeout = 2000,
    Map<String, String> headers = const {},
  }) => ProbeParams(
    url: 'http://target.invalid$path',
    proxyName: proxyName,
    timeout: timeout,
    maxBody: maxBody,
    headers: headers,
  );

  test(
    'socket endpoint correlates the actual request, arbitrary status and bounded body',
    () async {
      final result = await probe.probe(params());
      expect(result.error, isNull);
      expect(result.statusCode, 403);
      expect(result.delay, greaterThanOrEqualTo(0));
      expect(result.body, 'abcd');
      expect(result.chains, ['B', 'Selected']);
      expect(result.rule, 'final');
      expect(transport.outbounds, [null]);
      expect(transport.closed, 1);
    },
  );

  test(
    'redirect strips cross-origin credentials and correlates the final destination',
    () async {
      final result = await probe.probe(
        params(
          path: '/redirect',
          headers: {'Authorization': 'secret', 'Cookie': 'private'},
        ),
      );
      expect(result.error, isNull);
      expect(result.url, 'http://second.invalid/final');
      expect(result.chains, ['B', 'Selected']);
      expect(received.first.value('authorization'), 'secret');
      expect(received.last.value('authorization'), isNull);
      expect(received.last.value('cookie'), isNull);
    },
  );

  test('same-origin redirect matches only the final request socket', () async {
    final result = await probe.probe(params(path: '/same'));
    expect(result.error, isNull);
    expect(result.url, 'http://target.invalid/final');
    expect(result.chains, ['B', 'Selected']);
    expect(received, hasLength(2));
  });

  test(
    'explicit outbound is passed through without a selected-node fallback',
    () async {
      await probe.probe(params(proxyName: 'A'));
      await probe.probe(params(proxyName: 'DIRECT', maxBody: 0));
      expect(transport.outbounds, ['A', 'DIRECT']);
      expect(transport.closed, 2);
    },
  );

  test('missing or ambiguous telemetry does not manufacture a path', () async {
    duplicate = true;
    expect((await probe.probe(params())).chains, isEmpty);
    duplicate = false;
    observations.clear();
    alter = (entry) => entry['source_port'] = 1;
    final result = await probe.probe(params());
    expect(result.statusCode, 403);
    expect(result.error, isNull);
    expect(result.chains, isEmpty);
    expect(result.rule, isEmpty);
  });

  test(
    'old sockets and wrong inbound, network or destination cannot be mistaken for this probe',
    () async {
      for (final patch in [
        {'created_at': DateTime.utc(2000).toIso8601String()},
        {'created_at': DateTime.utc(2100).toIso8601String()},
        {'host': 'other.invalid'},
        {'inbound': 'unrelated'},
        {'network': 'udp'},
        {'destination_port': 9999},
        {'source_ip': '192.0.2.1'},
      ]) {
        observations.clear();
        alter = (entry) => entry.addAll(patch);
        expect((await probe.probe(params())).chains, isEmpty, reason: '$patch');
      }
    },
  );

  test(
    'timeout closes the scope and invalid requests never open a client',
    () async {
      final slow = await probe.probe(params(path: '/slow', timeout: 100));
      expect(slow.error, 'timeout');
      expect(transport.closed, 1);
      final invalid = [
        const ProbeParams(url: 'file:///private', timeout: 1000),
        const ProbeParams(
          url: 'http://name:secret@target.invalid',
          timeout: 1000,
        ),
        params(headers: {'X-Test': 'bad\r\nvalue'}),
        params(headers: {'Proxy-Authorization': 'secret'}),
        params(maxBody: 2 * 1024 * 1024),
      ];
      for (final request in invalid) {
        expect((await probe.probe(request)).error, 'failed');
      }
      expect(transport.outbounds, hasLength(1));
    },
  );

  test('an expired queued probe never starts a late request', () async {
    final active = [
      for (var i = 0; i < 8; i++) probe.probe(params(path: '/held')),
    ];
    while (received.length < 8) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final waiting = await probe.probe(params(timeout: 50));
    expect(waiting.error, 'timeout');
    hold.complete();
    await Future.wait(active);
    final next = await probe.probe(params());
    expect(next.statusCode, 403);
    expect(received, hasLength(9));
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_dns.dart';
import 'package:hotaru/core/config/dns.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';
import 'package:hotaru/core/sing_box/host_events.dart';

import 'support/dns_fixture.dart';
import 'loopback_proxy_fixture.dart';

final class _Resolver {
  final RawDatagramSocket socket;
  final Duration delay;
  final int address;
  int rcode = 0;
  final Map<String, int> receipts = {};
  final Set<Timer> _timers = {};

  _Resolver(this.socket, this.delay, this.address) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = socket.receive();
      if (packet == null) return;
      var offset = 12;
      final labels = <String>[];
      while (packet.data[offset] != 0) {
        final length = packet.data[offset++];
        labels.add(ascii.decode(packet.data.sublist(offset, offset + length)));
        offset += length;
      }
      final host = labels.join('.');
      receipts.update(host, (count) => count + 1, ifAbsent: () => 1);
      final response = answer(packet.data);
      response[3] = (response[3] & 0xf0) | rcode;
      if (rcode != 0) {
        response[7] = 0;
        response.removeRange(offset + 5, response.length);
      } else if (host.endsWith('-fixture.invalid')) {
        response.setRange(response.length - 4, response.length, [127, 0, 0, 1]);
      } else {
        response[response.length - 1] = address;
      }
      late Timer timer;
      timer = Timer(delay, () {
        _timers.remove(timer);
        socket.send(response, packet.address, packet.port);
      });
      _timers.add(timer);
    });
  }

  void close() {
    for (final timer in _timers) {
      timer.cancel();
    }
    socket.close();
  }
}

void main() {
  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlled = Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  test(
    'real DNS pools race upstreams, reject failures and resolve proxy endpoints through their pool',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-dns-groups-',
      );
      final first = _Resolver(
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        const Duration(milliseconds: 100),
        45,
      );
      final second = _Resolver(
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        const Duration(milliseconds: 5),
        46,
      );
      final reserved = <ServerSocket>[];
      Process? process;
      final output = <String>[];
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        origin.port,
      );
      var originReceipts = 0;
      origin.listen((request) async {
        originReceipts++;
        request.response.write('proxy-resolver-receipt');
        await request.response.close();
      });
      final client = HttpClient();
      try {
        Future<int> reserve() async {
          final socket = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          reserved.add(socket);
          return socket.port;
        }

        final mixed = await reserve();
        final api = await reserve();
        final incoming = await reserve();
        final ports = <String, int>{
          for (final tag in ['dns-bootstrap', 'dns-main', 'dns-proxy'])
            tag: await reserve(),
        };
        final addresses = [
          for (final resolver in [first, second])
            'udp://127.0.0.1:${resolver.socket.port}',
        ];
        final imported = importClashDns({
          'enable': true,
          'nameserver': [
            for (final resolver in [first, second])
              'udp://upstream-fixture.invalid:${resolver.socket.port}',
          ],
          'default-nameserver': addresses,
          'proxy-server-nameserver': addresses,
          'use-hosts': false,
          'use-system-hosts': false,
        });
        expect(imported.issues, isEmpty);
        final built = await SingBoxConfigBuilder().build(
          CoreProfileSpec(
            nodes: [
              CoreNodeSpec(
                tag: 'proxy',
                protocol: CoreNodeProtocol.http,
                server: 'proxy-fixture.invalid',
                port: proxy.server.port,
              ),
            ],
            selectors: [],
            finalOutbound: 'proxy',
            dns: imported.dns,
          ),
          CoreListenerSpec(
            mixedPort: mixed,
            controllerPort: api,
            secret: 'fixture',
            dnsPort: incoming,
            dnsGroups: CoreDnsGroupListeners(ports),
          ),
        );
        expect(built.issues, isEmpty);
        final config = await File(
          '${directory.path}/config.json',
        ).writeAsString(built.json!);
        final check = await Process.run(binary!, ['check', '-c', config.path]);
        expect(check.exitCode, 0, reason: '${check.stderr}');
        for (final socket in reserved) {
          await socket.close();
        }
        process = await Process.start(binary, [
          'run',
          '-c',
          config.path,
          if (controlled) '--stdio-control',
        ]);
        final host = SingBoxHostEvents(process.pid);
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              output.add(line);
              if (controlled) host.add(line);
            });
        process.stderr.transform(utf8.decoder).listen(output.add);
        if (controlled) await host.ready.timeout(const Duration(seconds: 10));
        var ready = false;
        for (var i = 0; i < 60; i++) {
          try {
            final socket = await Socket.connect(
              InternetAddress.loopbackIPv4,
              incoming,
            );
            socket.destroy();
            ready = true;
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        expect(ready, isTrue, reason: output.join());
        final fastest = await udpQuery(incoming, question('fastest.invalid'));
        expect(fastest.sublist(fastest.length - 4), [192, 0, 2, 46]);
        for (final rcode in [2, 5]) {
          second.rcode = rcode;
          final response = await udpQuery(
            incoming,
            question('failure-$rcode.invalid'),
          );
          expect(response.sublist(response.length - 4), [192, 0, 2, 45]);
        }
        second.rcode = 3;
        final negative = await udpQuery(incoming, question('negative.invalid'));
        expect(negative[3] & 0x0f, 3);
        first.rcode = 2;
        second.rcode = 5;
        final rejected = await udpQuery(
          incoming,
          question('unavailable.invalid'),
        );
        expect(rejected[3] & 0x0f, isNot(0));
        first.rcode = second.rcode = 0;
        client.findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${origin.port}/receipt'),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok, reason: output.join());
        expect(
          await response.transform(utf8.decoder).join(),
          'proxy-resolver-receipt',
        );
        expect(originReceipts, 1);
        expect(proxy.receipts, [origin.port]);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        for (final resolver in [first, second]) {
          for (final host in [
            'fastest.invalid',
            'failure-2.invalid',
            'failure-5.invalid',
            'negative.invalid',
            'unavailable.invalid',
            'upstream-fixture.invalid',
            'proxy-fixture.invalid',
          ]) {
            expect(
              resolver.receipts[host],
              greaterThan(0),
              reason: '$host / ${resolver.address}',
            );
          }
          expect(
            resolver.receipts['unavailable.invalid'],
            lessThanOrEqualTo(2),
          );
        }
      } finally {
        client.close(force: true);
        if (process != null) {
          if (controlled) {
            process.stdin.writeln('stop');
            await process.stdin.flush();
            await process.stdin.close();
            expect(
              await process.exitCode.timeout(const Duration(seconds: 5)),
              0,
            );
          } else {
            process.kill();
            await process.exitCode.timeout(const Duration(seconds: 5));
          }
        }
        first.close();
        second.close();
        await origin.close(force: true);
        await proxy.close();
        for (final socket in reserved) {
          await socket.close();
        }
        await directory.delete(recursive: true);
      }
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX for real engine DNS receipts'
        : false,
  );
}

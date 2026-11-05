import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_dns.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

List<int> question(String name, {int type = 1}) => [
  0x12,
  0x34,
  1,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  for (final part in name.split('.')) ...[part.length, ...ascii.encode(part)],
  0,
  0,
  type,
  0,
  1,
];

List<int> answer(List<int> query) {
  var end = 12;
  while (query[end] != 0) {
    end += query[end] + 1;
  }
  end += 5;
  final ipv4 = query[end - 3] == 1;
  return [
    ...query.take(2),
    0x81,
    0x80,
    0,
    1,
    0,
    ipv4 ? 1 : 0,
    0,
    0,
    0,
    0,
    ...query.sublist(12, end),
    if (ipv4) ...[0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 45],
  ];
}

Future<int> freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<List<int>> udpQuery(int port, List<int> query) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final response = Completer<List<int>>();
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final packet = socket.receive();
        if (packet != null && !response.isCompleted) {
          response.complete(packet.data);
        }
      }
    });
    socket.send(query, InternetAddress.loopbackIPv4, port);
    return await response.future.timeout(const Duration(seconds: 3));
  } finally {
    socket.close();
  }
}

Future<List<int>> tcpQuery(int port, List<int> query) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  try {
    final response = Completer<List<int>>();
    final buffer = <int>[];
    socket.listen(
      (bytes) {
        buffer.addAll(bytes);
        if (buffer.length >= 2) {
          final length = buffer[0] * 256 + buffer[1];
          if (buffer.length >= length + 2 && !response.isCompleted) {
            response.complete(buffer.sublist(2, length + 2));
          }
        }
      },
      onError: (Object error) {
        if (!response.isCompleted) response.completeError(error);
      },
    );
    socket.add([query.length >> 8, query.length & 255, ...query]);
    await socket.flush();
    return await response.future.timeout(const Duration(seconds: 3));
  } finally {
    socket.destroy();
  }
}

void main() {
  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  for (final protocol in ['udp', 'tcp']) {
    test(
      'real $protocol upstream, UDP/TCP inbound, cache and IPv6 policy',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hotaru-dns-wire-',
        );
        final upstream = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final udp = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          upstream.port,
        );
        final peers = <Socket>[];
        var udpReceipts = 0;
        var tcpReceipts = 0;
        final tcpReuseReady = Completer<void>();
        final tcpIds = <int>[];
        Process? process;
        final output = <String>[];
        udp.listen((event) {
          if (event != RawSocketEvent.read) return;
          final packet = udp.receive();
          if (packet == null) return;
          udpReceipts++;
          udp.send(answer(packet.data), packet.address, packet.port);
        });
        upstream.listen((socket) {
          peers.add(socket);
          final buffer = <int>[];
          socket.listen((bytes) {
            buffer.addAll(bytes);
            while (buffer.length >= 2) {
              final length = buffer[0] * 256 + buffer[1];
              if (buffer.length < length + 2) break;
              tcpIds.add(buffer[2] * 256 + buffer[3]);
              final response = answer(buffer.sublist(2, length + 2));
              buffer.removeRange(0, length + 2);
              tcpReceipts++;
              if (tcpReceipts == 3) tcpReuseReady.complete();
              socket.add([
                response.length >> 8,
                response.length & 255,
                ...response,
              ]);
            }
          });
        });
        try {
          final dnsPort = await freePort();
          final mixedPort = await freePort();
          final apiPort = await freePort();
          final imported = importClashDns({
            'enable': true,
            'nameserver': ['$protocol://127.0.0.1:${upstream.port}'],
            'use-hosts': false,
            'use-system-hosts': false,
            'cache-size': 64,
          });
          expect(imported.issues, isEmpty);
          final built = await SingBoxConfigBuilder().build(
            CoreProfileSpec(
              nodes: [
                const CoreNodeSpec(
                  tag: 'direct',
                  protocol: CoreNodeProtocol.direct,
                ),
              ],
              selectors: [],
              finalOutbound: 'direct',
              dns: imported.dns,
            ),
            CoreListenerSpec(
              mixedPort: mixedPort,
              controllerPort: apiPort,
              secret: 'local-fixture',
              dnsPort: dnsPort,
            ),
          );
          expect(built.issues, isEmpty);
          final config = File('${directory.path}/config.json');
          await config.writeAsString(built.json!);
          process = await Process.start(binary!, ['run', '-c', config.path]);
          process.stdout.transform(utf8.decoder).listen(output.add);
          process.stderr.transform(utf8.decoder).listen(output.add);
          var ready = false;
          for (var i = 0; i < 60; i++) {
            try {
              final connection = await Socket.connect(
                InternetAddress.loopbackIPv4,
                dnsPort,
              );
              connection.destroy();
              ready = true;
              break;
            } on SocketException {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
          expect(ready, isTrue, reason: output.join());
          final query = question('wire-fixture.invalid');
          final first = await udpQuery(dnsPort, query);
          expect(first.sublist(first.length - 4), [192, 0, 2, 45]);
          if (protocol == 'tcp') {
            await tcpReuseReady.future.timeout(const Duration(seconds: 3));
            expect(tcpIds, unorderedEquals([0x1234, 1, 2]));
          }
          final expectedReceipts = protocol == 'udp' ? 1 : 3;
          expect(
            protocol == 'udp' ? udpReceipts : tcpReceipts,
            expectedReceipts,
          );
          expect(protocol == 'udp' ? tcpReceipts : udpReceipts, 0);
          final cached = await tcpQuery(dnsPort, query);
          expect(cached.sublist(cached.length - 4), [192, 0, 2, 45]);
          expect(
            udpReceipts + tcpReceipts,
            expectedReceipts,
            reason: 'second query must use cache',
          );
          final ipv6 = await udpQuery(
            dnsPort,
            question('ipv6-fixture.invalid', type: 28),
          );
          expect(ipv6.sublist(6, 8), [0, 0]);
          expect(
            udpReceipts + tcpReceipts,
            expectedReceipts,
            reason: 'IPv6 disabled before upstream',
          );
        } finally {
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(const Duration(seconds: 5));
          }
          for (final peer in peers) {
            peer.destroy();
          }
          udp.close();
          await upstream.close();
          await directory.delete(recursive: true);
        }
      },
      skip: binary == null
          ? 'Set HOTARU_TEST_SING_BOX for real DNS receipts'
          : false,
    );
  }
}

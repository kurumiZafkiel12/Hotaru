import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hotaru/common/network_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List response(Uint8List transaction, InternetAddress address, int port) {
  final raw = address.rawAddress;
  final packet = Uint8List(28 + raw.length);
  final bytes = ByteData.sublistView(packet);
  bytes.setUint16(0, 0x0101);
  bytes.setUint16(2, packet.length - 20);
  bytes.setUint32(4, 0x2112a442);
  packet.setRange(8, 20, transaction);
  bytes.setUint16(20, 0x0020);
  bytes.setUint16(22, raw.length + 4);
  packet[25] = raw.length == 4 ? 1 : 2;
  bytes.setUint16(26, port ^ 0x2112);
  final mask = Uint8List(16);
  ByteData.sublistView(mask).setUint32(0, 0x2112a442);
  mask.setRange(4, 16, transaction);
  for (var i = 0; i < raw.length; i++) {
    packet[28 + i] = raw[i] ^ mask[i];
  }
  return packet;
}

void main() {
  final transaction = Uint8List.fromList(List.generate(12, (i) => i + 1));

  test('decodes transaction-bound IPv4 and IPv6 XOR mapped addresses', () {
    for (final ip in ['8.8.4.4', '2606:4700:4700::1111']) {
      final parsed = parseStunResponse(
        response(transaction, InternetAddress(ip), 49153),
        transaction,
      );
      expect(parsed!.address.address, InternetAddress(ip).address);
      expect(parsed.port, 49153);
    }
  });

  test(
    'rejects a wrong transaction, non-binding response and truncated attributes',
    () {
      final packet = response(transaction, InternetAddress('8.8.8.8'), 50000);
      expect(parseStunResponse(packet, Uint8List(12)), isNull);
      expect(
        parseStunResponse(packet.sublist(0, packet.length - 1), transaction),
        isNull,
      );
      final wrongType = Uint8List.fromList(packet)..[0] = 0x11;
      expect(parseStunResponse(wrongType, transaction), isNull);
      final wrongLength = Uint8List.fromList(packet)..[23] = 40;
      expect(parseStunResponse(wrongLength, transaction), isNull);
    },
  );

  test(
    'does not classify local, fake-IP, documentation or shared addresses as public',
    () {
      for (final ip in [
        '0.0.0.0',
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '192.168.0.1',
        '100.64.0.1',
        '198.18.0.1',
        '192.0.2.1',
        '203.0.113.4',
        '::',
        '::1',
        'fc00::1',
        'fe80::1',
        '2001:db8::1',
        '::ffff:192.168.1.1',
      ]) {
        expect(isPublicProbeAddress(InternetAddress(ip)), isFalse, reason: ip);
      }
      expect(isPublicProbeAddress(InternetAddress('8.8.8.8')), isTrue);
      expect(
        isPublicProbeAddress(InternetAddress('2606:4700:4700::1111')),
        isTrue,
      );
    },
  );

  test(
    'real UDP probe ignores spoofed source ports and unrelated transactions',
    () async {
      final server = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final spoof = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final probe = StunProbe();
      addTearDown(() {
        probe.cancel();
        server.close();
        spoof.close();
      });
      final subscription = server.listen((event) {
        if (event != RawSocketEvent.read) return;
        final request = server.receive();
        if (request == null) return;
        final transaction = Uint8List.fromList(request.data.sublist(8, 20));
        spoof.send(
          response(transaction, InternetAddress('1.1.1.1'), 1000),
          request.address,
          request.port,
        );
        server.send(
          response(Uint8List(12), InternetAddress('1.0.0.1'), 2000),
          request.address,
          request.port,
        );
        server.send(
          response(transaction, InternetAddress('8.8.4.4'), 3000),
          request.address,
          request.port,
        );
      });
      addTearDown(subscription.cancel);
      final result = await probe.run('127.0.0.1', server.port);
      expect(result.address.address, '8.8.4.4');
      expect(result.port, 3000);
    },
  );

  test(
    'cancel closes a pending UDP probe without waiting for its timeout',
    () async {
      final server = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final entered = Completer<void>();
      final subscription = server.listen((event) {
        if (event == RawSocketEvent.read &&
            server.receive() != null &&
            !entered.isCompleted) {
          entered.complete();
        }
      });
      final probe = StunProbe();
      addTearDown(() {
        probe.cancel();
        server.close();
      });
      addTearDown(subscription.cancel);
      final pending = probe.run('127.0.0.1', server.port);
      final checked = expectLater(pending, throwsA(isA<SocketException>()));
      await entered.future.timeout(const Duration(seconds: 2));
      probe.cancel();
      await checked.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'Windows recovery clears PAC and proxy independently and reports failure',
    () async {
      final calls = <(String, List<String>)>[];
      final result = await clearWindowsPac((exe, args) async {
        calls.add((exe, args));
        return ProcessResult(1, args.contains('AutoConfigURL') ? 1 : 0, '', '');
      });
      expect(result, isFalse);
      expect(calls, hasLength(2));
      expect(calls.every((call) => call.$1 == 'reg.exe'), isTrue);
      expect(calls.any((call) => call.$2.contains('AutoConfigURL')), isTrue);
      expect(
        calls.any(
          (call) => call.$2.contains('ProxyEnable') && call.$2.contains('0'),
        ),
        isTrue,
      );
    },
  );
}

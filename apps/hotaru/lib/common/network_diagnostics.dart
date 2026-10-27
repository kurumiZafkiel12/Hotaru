import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const _stunCookie = 0x2112a442;

class StunEndpoint {
  const StunEndpoint(this.address, this.port);

  final InternetAddress address;
  final int port;

  @override
  String toString() => '${address.address}:$port';
}

StunEndpoint? parseStunResponse(Uint8List packet, Uint8List transaction) {
  if (packet.length < 20 || transaction.length != 12) return null;
  final bytes = ByteData.sublistView(packet);
  if (bytes.getUint16(0) != 0x0101 || bytes.getUint32(4) != _stunCookie) {
    return null;
  }
  final length = bytes.getUint16(2);
  if (length % 4 != 0 || length + 20 > packet.length) return null;
  for (var i = 0; i < 12; i++) {
    if (packet[i + 8] != transaction[i]) return null;
  }
  StunEndpoint? mapped;
  for (var at = 20; at + 4 <= length + 20;) {
    final type = bytes.getUint16(at);
    final size = bytes.getUint16(at + 2);
    final start = at + 4;
    if (start + size > length + 20) return null;
    if ((type == 0x0020 || type == 0x0001) && size >= 8) {
      final family = packet[start + 1];
      final addressLength = family == 1
          ? 4
          : family == 2
          ? 16
          : 0;
      if (addressLength != 0 && size == addressLength + 4) {
        final mask = Uint8List(16);
        ByteData.sublistView(mask).setUint32(0, _stunCookie);
        mask.setRange(4, 16, transaction);
        final raw = Uint8List(addressLength);
        for (var i = 0; i < addressLength; i++) {
          raw[i] = packet[start + 4 + i] ^ (type == 0x0020 ? mask[i] : 0);
        }
        final endpoint = StunEndpoint(
          InternetAddress.fromRawAddress(raw),
          bytes.getUint16(start + 2) ^ (type == 0x0020 ? _stunCookie >> 16 : 0),
        );
        if (type == 0x0020) return endpoint;
        mapped = endpoint;
      }
    }
    at = start + ((size + 3) & ~3);
  }
  return mapped;
}

bool isPublicProbeAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  if (bytes.length == 4) {
    return bytes[0] != 0 &&
        bytes[0] != 10 &&
        bytes[0] != 127 &&
        !(bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) &&
        !(bytes[0] == 192 && bytes[1] == 168) &&
        !(bytes[0] == 192 &&
            bytes[1] == 0 &&
            (bytes[2] == 0 || bytes[2] == 2)) &&
        !(bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) &&
        !(bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113) &&
        !(bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) &&
        !(bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)) &&
        bytes[0] < 224;
  }
  if (bytes.take(10).every((value) => value == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255) {
    return isPublicProbeAddress(
      InternetAddress.fromRawAddress(Uint8List.fromList(bytes.sublist(12))),
    );
  }
  return (bytes[0] & 0xe0) == 0x20 &&
      !(bytes[0] == 0x20 &&
          bytes[1] == 0x01 &&
          bytes[2] == 0x0d &&
          bytes[3] == 0xb8);
}

class StunProbe {
  RawDatagramSocket? _socket;
  Completer<StunEndpoint>? _pending;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const SocketException('cancelled'));
    }
    _socket?.close();
  }

  Future<StunEndpoint> run(
    String host,
    int port, {
    InternetAddressType family = InternetAddressType.IPv4,
  }) async {
    final addresses = await InternetAddress.lookup(
      host,
      type: family,
    ).timeout(const Duration(seconds: 5));
    if (_cancelled) throw const SocketException('cancelled');
    if (addresses.isEmpty) {
      throw const SocketException('no STUN server address');
    }
    final server = addresses.first;
    final socket = await RawDatagramSocket.bind(
      server.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    _socket = socket;
    if (_cancelled) {
      socket.close();
      throw const SocketException('cancelled');
    }
    final transaction = Uint8List.fromList(
      List.generate(12, (_) => Random.secure().nextInt(256)),
    );
    final request = Uint8List(20);
    final bytes = ByteData.sublistView(request);
    bytes.setUint16(0, 0x0001);
    bytes.setUint32(4, _stunCookie);
    request.setRange(8, 20, transaction);
    final completer = Completer<StunEndpoint>();
    _pending = completer;
    final subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          final reply = datagram!;
          if (reply.address.address != server.address || reply.port != port) {
            continue;
          }
          final endpoint = parseStunResponse(reply.data, transaction);
          if (endpoint != null && !completer.isCompleted) {
            completer.complete(endpoint);
          }
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    final retry = Timer.periodic(
      const Duration(milliseconds: 750),
      (_) => socket.send(request, server, port),
    );
    socket.send(request, server, port);
    try {
      return await completer.future.timeout(const Duration(seconds: 5));
    } finally {
      retry.cancel();
      await subscription.cancel();
      socket.close();
      _socket = null;
      _pending = null;
    }
  }
}

typedef RecoveryCommand =
    Future<ProcessResult> Function(String executable, List<String> arguments);

Future<bool> clearWindowsPac(RecoveryCommand run) async {
  const key =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  final results = await Future.wait([
    run('reg.exe', [
      'add',
      key,
      '/v',
      'AutoConfigURL',
      '/t',
      'REG_SZ',
      '/d',
      '',
      '/f',
    ]),
    run('reg.exe', [
      'add',
      key,
      '/v',
      'ProxyEnable',
      '/t',
      'REG_DWORD',
      '/d',
      '0',
      '/f',
    ]),
  ]);
  return results.every((result) => result.exitCode == 0);
}

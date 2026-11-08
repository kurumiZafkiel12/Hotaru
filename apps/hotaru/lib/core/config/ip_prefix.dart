import 'dart:io';

final class CoreIpPrefix {
  final InternetAddress network;
  final int prefix;

  const CoreIpPrefix._(this.network, this.prefix);

  static CoreIpPrefix? parse(String value) {
    final parts = value.split('/');
    if (parts.length != 2 ||
        !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(parts.last) ||
        parts.first.contains(RegExp(r'[%\[\]]'))) {
      return null;
    }
    final network = InternetAddress.tryParse(parts.first);
    final prefix = int.tryParse(parts.last);
    if (network == null ||
        prefix == null ||
        prefix < 0 ||
        prefix > network.rawAddress.length * 8) {
      return null;
    }
    if (network.type == InternetAddressType.IPv4 &&
        network.address != parts.first) {
      return null;
    }
    final bytes = network.rawAddress;
    if (bytes.length == 16 &&
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return null;
    }
    return CoreIpPrefix._(network, prefix);
  }

  bool contains(InternetAddress address) {
    final bytes = address.rawAddress;
    final networkBytes = network.rawAddress;
    if (bytes.length != networkBytes.length) return false;
    for (var index = 0; index < prefix ~/ 8; index++) {
      if (bytes[index] != networkBytes[index]) return false;
    }
    final remainder = prefix % 8;
    if (remainder == 0) return true;
    final mask = (0xff << (8 - remainder)) & 0xff;
    return bytes[prefix ~/ 8] & mask == networkBytes[prefix ~/ 8] & mask;
  }
}

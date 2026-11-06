import 'dart:convert';

final class CoreProbeListenerSpec {
  final int port;
  final String secret;

  const CoreProbeListenerSpec({required this.port, required this.secret});

  bool get isValid =>
      port > 0 &&
      port <= 65535 &&
      RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(secret);

  static String username(String outbound) =>
      'hotaru.${base64Url.encode(utf8.encode(outbound)).replaceAll('=', '')}';
}

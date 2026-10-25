import 'dart:async';
import 'dart:io';

enum DiagnosticKind { dns, tcp, http }

class NetworkDiagnostics {
  const NetworkDiagnostics();

  String hostOf(String input) {
    final value = input.trim();
    final address = InternetAddress.tryParse(value);
    if (address != null) return address.address;
    final uri = Uri.tryParse(value.contains('://') ? value : 'tcp://$value');
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid host');
    }
    return uri.host;
  }

  Future<String> resolve(String input) async {
    final addresses = await InternetAddress.lookup(
      hostOf(input),
    ).timeout(const Duration(seconds: 8));
    return addresses
        .map((address) => '${address.type.name}: ${address.address}')
        .toSet()
        .join('\n');
  }

  Future<String> tcp(String input) async {
    final uri = Uri.tryParse('tcp://${input.trim()}');
    if (uri == null || !uri.hasPort || uri.port < 1 || uri.port > 65535) {
      throw const FormatException('Use host:port or [IPv6]:port');
    }
    final host = hostOf(input);
    final results = <String>[];
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      final socket = await Socket.connect(
        host,
        uri.port,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      results.add('${i + 1}: ${watch.elapsedMicroseconds / 1000} ms');
    }
    return results.join('\n');
  }

  Future<String> http(String input) async {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Use an HTTP/HTTPS URL');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final watch = Stopwatch()..start();
    try {
      final request = await client
          .headUrl(uri)
          .timeout(const Duration(seconds: 8));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final elapsed = watch.elapsedMilliseconds;
      final location = response.headers.value(HttpHeaders.locationHeader);
      return 'HTTP ${response.statusCode}\n$elapsed ms'
          '${location == null ? '' : '\nLocation: $location'}';
    } finally {
      client.close(force: true);
    }
  }

  Future<String> run(DiagnosticKind kind, String input) => switch (kind) {
    DiagnosticKind.dns => resolve(input),
    DiagnosticKind.tcp => tcp(input),
    DiagnosticKind.http => http(input),
  };
}

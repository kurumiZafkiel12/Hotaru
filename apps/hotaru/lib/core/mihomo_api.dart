import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal client for Mihomo's loopback control API. Every request carries
/// the per-launch random secret; nothing here ever leaves 127.0.0.1.
class MihomoApi {
  final int port;
  final String secret;
  final HttpClient _http;
  final _sockets = <WebSocket>{};
  bool _closed = false;

  MihomoApi({required this.port, required this.secret, HttpClient? http})
    : _http = http ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 2);
  }

  Uri _uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  Future<(int, String)> _send(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final request = await _http.openUrl(method, _uri(path)).timeout(timeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    return (response.statusCode, text);
  }

  Future<String> version() async {
    final (code, text) = await _send('GET', '/version');
    if (code != 200) throw StateError('Core API /version returned $code');
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['version'] is! String) {
      throw StateError('Core API /version malformed');
    }
    return decoded['version'] as String;
  }

  /// All proxies and groups: name → info map (type, now, all, history…).
  Future<Map<String, dynamic>> proxies() async {
    final (code, text) = await _send('GET', '/proxies');
    if (code != 200) throw StateError('Core API /proxies returned $code');
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['proxies'] is! Map) {
      throw StateError('Core API /proxies malformed');
    }
    return (decoded['proxies'] as Map).cast<String, dynamic>();
  }

  /// Finds a selector group that contains [node] and switches it. Returns
  /// the group name used, or null when no selector contains the node (e.g.
  /// the node is routed some other way in a full config).
  ///
  /// Mihomo's built-in GLOBAL selector also contains every node, but in
  /// rule mode it decides nothing; it is only used as a last resort. The
  /// app's own HOTARU group wins first, then any user group.
  Future<String?> selectNode(String node) async {
    final all = await proxies();
    final candidates = <String>[];
    for (final entry in all.entries) {
      final info = entry.value;
      if (info is Map &&
          info['type'] == 'Selector' &&
          info['all'] is List &&
          (info['all'] as List).contains(node)) {
        candidates.add(entry.key);
      }
    }
    if (candidates.isEmpty) return null;
    int rank(String name) => name == 'HOTARU' ? 0 : (name == 'GLOBAL' ? 2 : 1);
    candidates.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.compareTo(b);
    });
    final group = candidates.first;
    await select(group, node);
    return group;
  }

  Future<void> select(String group, String name) async {
    final (code, _) = await _send(
      'PUT',
      '/proxies/${Uri.encodeComponent(group)}',
      body: {'name': name},
    );
    if (code != 204 && code != 200) {
      throw StateError('Core API select returned $code');
    }
  }

  /// Real latency probe through the core (Mihomo measures the node itself).
  /// Returns milliseconds, or null on timeout/failure — callers must show
  /// that as “failed/unknown”, never as a made-up number.
  Future<int?> delay(
    String name, {
    String? provider,
    String url = 'http://www.gstatic.com/generate_204',
    int timeoutMs = 5000,
  }) async {
    try {
      final (code, text) = await _send(
        'GET',
        '${provider == null || provider.isEmpty ? '/proxies/${Uri.encodeComponent(name)}/delay' : '/providers/proxies/${Uri.encodeComponent(provider)}/${Uri.encodeComponent(name)}/healthcheck'}'
            '?timeout=$timeoutMs&url=${Uri.encodeComponent(url)}',
        timeout: Duration(milliseconds: timeoutMs + 2000),
      );
      if (code != 200) return null;
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['delay'] is int) {
        return decoded['delay'] as int;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Snapshot of current connections (used by diagnostics and the future
  /// connection-records feature). Returns the raw decoded JSON map.
  Future<Map<String, dynamic>> connections() async {
    final (code, text) = await _send('GET', '/connections');
    if (code != 200) throw StateError('Core API /connections returned $code');
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Core API /connections malformed');
    }
    return decoded;
  }

  void close() {
    _closed = true;
    for (final socket in _sockets.toList()) {
      unawaited(socket.close());
    }
    _sockets.clear();
    _http.close(force: true);
  }

  Future<Map<String, dynamic>> getMap(String path) async {
    final (code, text) = await _send('GET', path);
    if (code != 200) throw StateError('Core API returned $code');
    return (jsonDecode(text) as Map).cast<String, dynamic>();
  }

  Future<void> setMode(String mode) async {
    if (!['rule', 'global', 'direct'].contains(mode)) {
      throw ArgumentError('mode');
    }
    final (code, _) = await _send('PATCH', '/configs', body: {'mode': mode});
    if (code != 204 && code != 200) throw StateError('Mode update failed');
  }

  Future<void> updateProvider(String name, {bool rules = false}) async {
    final (code, _) = await _send(
      'PUT',
      '/providers/${rules ? 'rules' : 'proxies'}/${Uri.encodeComponent(name)}',
    );
    if (code != 204 && code != 200) throw StateError('Provider update failed');
  }

  Stream<Map<String, dynamic>> events(String path) {
    late StreamController<Map<String, dynamic>> controller;
    WebSocket? socket;
    StreamSubscription<dynamic>? subscription;
    var canceled = false;
    controller = StreamController<Map<String, dynamic>>(
      onListen: () async {
        try {
          socket = await WebSocket.connect(
            'ws://127.0.0.1:$port$path',
            headers: {HttpHeaders.authorizationHeader: 'Bearer $secret'},
          ).timeout(const Duration(seconds: 5));
          if (canceled || _closed) {
            await socket!.close();
            return;
          }
          _sockets.add(socket!);
          subscription = socket!.listen(
            (event) {
              try {
                controller.add(
                  (jsonDecode(event as String) as Map).cast<String, dynamic>(),
                );
              } catch (e, st) {
                controller.addError(e, st);
              }
            },
            onError: controller.addError,
            onDone: () {
              _sockets.remove(socket);
              unawaited(controller.close());
            },
          );
        } catch (e, st) {
          if (!canceled) {
            controller.addError(e, st);
            await controller.close();
          }
        }
      },
      onCancel: () async {
        canceled = true;
        _sockets.remove(socket);
        await subscription?.cancel();
        await socket?.close();
      },
    );
    return controller.stream;
  }

  Future<void> closeConnection(String id) async {
    final (code, _) = await _send(
      'DELETE',
      '/connections/${Uri.encodeComponent(id)}',
    );
    if (code != 204 && code != 200) throw StateError('Close connection failed');
  }
}

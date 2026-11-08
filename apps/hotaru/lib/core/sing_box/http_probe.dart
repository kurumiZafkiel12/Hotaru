import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../common/task_pool.dart';
import '../../models/core.dart';
import '../adapter.dart';
import '../routed_http.dart';
import '../telemetry.dart';

final class SingBoxHttpProbe {
  final CoreRoutedHttp transport;
  final Future<CoreTelemetrySnapshot> Function() observe;
  final TaskPool _pool = TaskPool(8);

  SingBoxHttpProbe({required this.transport, required this.observe});

  Future<ProbeResult> probe(
    ProbeParams params, {
    Future<void>? cancelled,
  }) async {
    var stopped = false;
    final cancellation = cancelled?.then<ProbeResult>((_) {
      stopped = true;
      throw const CoreAdapterException('cancelled');
    });
    cancellation?.ignore();
    final watch = Stopwatch()..start();
    final timeout = Duration(
      milliseconds: params.timeout <= 0 ? 10000 : params.timeout,
    );
    try {
      if (timeout > const Duration(minutes: 2) ||
          params.maxBody < 0 ||
          params.maxBody > 8 * 1024 * 1024 ||
          _pool.pendingCount >= 64) {
        throw const CoreAdapterException('invalid_probe_bounds');
      }
      if (params.url.length > 8192) {
        throw const CoreAdapterException('invalid_probe_url');
      }
      final uri = Uri.parse(params.url);
      _validateUrl(uri);
      final headers = <String, String>{};
      if (params.headers.length > 64) {
        throw const CoreAdapterException('invalid_probe_headers');
      }
      var headerBytes = 0;
      for (final entry in params.headers.entries) {
        if (entry.key.length > 128 || entry.value.length > 8192) {
          throw const CoreAdapterException('invalid_probe_headers');
        }
        final key = entry.key.toLowerCase();
        headerBytes +=
            utf8.encode(entry.key).length + utf8.encode(entry.value).length;
        if (key.length > 128 ||
            !RegExp(r"^[!#$%&'*+.^_`|~0-9a-z-]+$").hasMatch(key) ||
            headers.containsKey(key) ||
            headerBytes > 65536 ||
            entry.value.length > 8192 ||
            entry.value.contains(RegExp(r'[\x00-\x08\x0a-\x1f\x7f]')) ||
            const {
              'connection',
              'content-length',
              'transfer-encoding',
              'proxy-authorization',
              'upgrade',
            }.contains(key)) {
          throw const CoreAdapterException('invalid_probe_headers');
        }
        headers[key] = entry.value;
      }
      final pending = _pool
          .run(() {
            if (stopped) throw const CoreAdapterException('cancelled');
            final remaining = timeout - watch.elapsed;
            if (remaining <= Duration.zero) {
              throw const CoreAdapterException('timeout');
            }
            return transport.withRoutedClient(
              (client) => cancellation == null
                  ? _request(client, uri, headers, params.maxBody)
                  : Future.any([
                      _request(client, uri, headers, params.maxBody),
                      cancellation,
                    ]),
              outbound: params.proxyName.isEmpty ? null : params.proxyName,
              timeout: remaining,
            );
          })
          .timeout(timeout);
      return await (cancellation == null
          ? pending
          : Future.any([pending, cancellation]));
    } catch (error) {
      final timedOut =
          error is TimeoutException ||
          error is CoreAdapterException && error.code == 'timeout';
      return ProbeResult(
        url: params.url,
        error: timedOut ? 'timeout' : 'failed',
        message: error is CoreAdapterException ? error.code : 'probe_failed',
      );
    }
  }

  Future<ProbeResult> _request(
    HttpClient client,
    Uri initial,
    Map<String, String> headers,
    int maxBody,
  ) async {
    final sockets = <_ProbeSocket>[];
    var active = true;
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final started = DateTime.now().toUtc();
      final task = await Socket.startConnect(
        proxyHost ?? uri.host,
        proxyPort ?? uri.port,
      );
      return ConnectionTask.fromSocket(
        task.socket.then((socket) {
          if (!active) {
            socket.destroy();
            throw const CoreAdapterException('probe_scope_closed');
          }
          if (proxyHost != null) {
            sockets.add(
              _ProbeSocket(socket.port, socket.address.address, started),
            );
          }
          return socket;
        }),
        task.cancel,
      );
    };
    final watch = Stopwatch()..start();
    try {
      var target = initial;
      var requestHeaders = headers;
      for (var redirects = 0; ; redirects++) {
        final socketIndex = sockets.length;
        final request = await client.getUrl(target);
        request.followRedirects = false;
        request.persistentConnection = false;
        requestHeaders.forEach(request.headers.set);
        final response = await request.close();
        final receivedAt = DateTime.now().toUtc();
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode) &&
            response.headers.value('location') != null) {
          final location = response.headers.value('location')!;
          await response.listen((_) {}, onError: (Object _) {}).cancel();
          if (redirects >= 10) {
            throw const CoreAdapterException('probe_redirect_limit');
          }
          final next = target.resolve(location).removeFragment();
          _validateUrl(next);
          if (target.scheme == 'https' && next.scheme != 'https') {
            throw const CoreAdapterException('unsafe_probe_redirect');
          }
          if (next.origin != target.origin) {
            requestHeaders = {
              for (final entry in requestHeaders.entries)
                if (!const {
                  'authorization',
                  'cookie',
                  'cookie2',
                  'host',
                }.contains(entry.key))
                  entry.key: entry.value,
            };
          }
          target = next;
          continue;
        }
        final delay = watch.elapsedMilliseconds;
        final body = BytesBuilder(copy: false);
        if (maxBody == 0) {
          await response.listen((_) {}, onError: (Object _) {}).cancel();
        } else {
          await for (final chunk in response) {
            final remaining = maxBody - body.length;
            body.add(
              chunk.length > remaining ? chunk.sublist(0, remaining) : chunk,
            );
            if (body.length == maxBody) break;
          }
        }
        final observed = await _observation(
          sockets.sublist(socketIndex),
          target,
          receivedAt,
        );
        final bytes = body.takeBytes();
        return ProbeResult(
          url: target.toString(),
          statusCode: response.statusCode,
          delay: delay,
          body: await _decodeBody(bytes),
          chains: observed == null
              ? const []
              : observed.chain.isNotEmpty
              ? observed.chain
              : [if (observed.outbound.isNotEmpty) observed.outbound],
          rule: observed?.rule ?? '',
        );
      }
    } finally {
      active = false;
    }
  }

  Future<CoreObservedConnection?> _observation(
    List<_ProbeSocket> sockets,
    Uri target,
    DateTime receivedAt,
  ) async {
    if (sockets.isEmpty) return null;
    try {
      final data = await observe();
      return await _matchObservation(data, sockets, target, receivedAt);
    } catch (_) {
      return null;
    }
  }
}

final class _ProbeSocket {
  final int port;
  final String address;
  final DateTime started;

  const _ProbeSocket(this.port, this.address, this.started);
}

void _validateUrl(Uri uri) {
  if (!const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.toString().length > 8192) {
    throw const CoreAdapterException('invalid_probe_url');
  }
}

bool _sameHost(String first, String second) {
  final a = InternetAddress.tryParse(first);
  final b = InternetAddress.tryParse(second);
  return a != null && b != null
      ? a == b
      : first.toLowerCase() == second.toLowerCase();
}

Future<String> _decodeBody(Uint8List bytes) =>
    Isolate.run(() => utf8.decode(bytes, allowMalformed: true));

Future<CoreObservedConnection?> _matchObservation(
  CoreTelemetrySnapshot data,
  List<_ProbeSocket> sockets,
  Uri target,
  DateTime receivedAt,
) => Isolate.run(() {
  final matches = <String, CoreObservedConnection>{};
  for (final entry in [...data.active, ...data.closed]) {
    if (entry.network != 'tcp' ||
        !const {'mixed', 'hotaru-probe'}.contains(entry.inbound) ||
        entry.destinationPort != target.port ||
        entry.createdAt.isAfter(receivedAt)) {
      continue;
    }
    final destination = entry.host.isEmpty ? entry.destinationIp : entry.host;
    if (!_sameHost(destination, target.host)) continue;
    if (sockets.any(
      (socket) =>
          socket.port == entry.sourcePort &&
          _sameHost(socket.address, entry.sourceIp) &&
          !entry.createdAt.isBefore(socket.started),
    )) {
      matches[entry.id] = entry;
    }
  }
  return matches.length == 1 ? matches.values.single : null;
});

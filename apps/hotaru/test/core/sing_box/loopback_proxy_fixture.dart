import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<int> freeLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

class LoopbackProxyFixture {
  LoopbackProxyFixture(this.server, this.targetPort) {
    server.listen(_connect);
  }
  final ServerSocket server;
  final int targetPort;
  final receipts = <int>[];
  final cleanups = <Future<void> Function()>[];

  void _connect(Socket downstream) {
    final header = <int>[];
    Socket? upstream;
    late StreamSubscription<List<int>> subscription;
    var closed = false;
    Future<void> cleanup() async {
      closed = true;
      downstream.destroy();
      upstream?.destroy();
      await subscription.cancel();
    }

    cleanups.add(cleanup);
    Future<void> establish(int boundary) async {
      try {
        final line = ascii
            .decode(header.sublist(0, boundary))
            .split('\r\n')
            .first;
        final target = RegExp(
          r'^CONNECT 127\.0\.0\.1:(\d+) HTTP/1\.1$',
        ).firstMatch(line);
        if (int.tryParse(target?.group(1) ?? '') != targetPort) {
          await cleanup();
          return;
        }
        final connection = await Socket.connect(
          InternetAddress.loopbackIPv4,
          targetPort,
        );
        if (closed) {
          connection.destroy();
          return;
        }
        upstream = connection;
        receipts.add(targetPort);
        downstream.add(
          ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'),
        );
        connection.listen(
          downstream.add,
          onDone: downstream.destroy,
          onError: (Object _) => downstream.destroy(),
        );
        if (header.length > boundary + 4) {
          connection.add(header.sublist(boundary + 4));
        }
        header.clear();
        subscription.resume();
      } catch (_) {
        await cleanup();
      }
    }

    subscription = downstream.listen(
      (bytes) {
        final connection = upstream;
        if (connection != null) {
          connection.add(bytes);
          return;
        }
        header.addAll(bytes);
        if (header.length > 16384) {
          downstream.destroy();
          return;
        }
        for (var i = 0; i + 3 < header.length; i++) {
          if (header[i] == 13 &&
              header[i + 1] == 10 &&
              header[i + 2] == 13 &&
              header[i + 3] == 10) {
            subscription.pause();
            unawaited(establish(i));
            break;
          }
        }
      },
      onDone: () => unawaited(cleanup()),
      onError: (Object _) => unawaited(cleanup()),
    );
  }

  Future<void> close() async {
    await server.close();
    for (final cleanup in cleanups) {
      await cleanup();
    }
  }
}

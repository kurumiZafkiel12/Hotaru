import 'dart:io';

import 'package:hotaru/common/network_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const diagnostics = NetworkDiagnostics();

  test('host parsing supports URLs and IPv6 and rejects credentials', () {
    expect(diagnostics.hostOf('https://example.com/path'), 'example.com');
    expect(diagnostics.hostOf('[::1]:443'), '::1');
    expect(
      () => diagnostics.hostOf('https://user:secret@example.com'),
      throwsFormatException,
    );
  });

  test(
    'TCP probes close their sockets and require an explicit valid port',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((socket) => socket.destroy());
      addTearDown(() async {
        await subscription.cancel();
        await server.close();
      });
      final result = await diagnostics.tcp('127.0.0.1:${server.port}');
      expect(result.split('\n'), hasLength(3));
      await expectLater(diagnostics.tcp('localhost'), throwsFormatException);
      await expectLater(diagnostics.tcp('localhost:0'), throwsFormatException);
    },
  );

  test('HTTP reports actual status without following a redirect', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, '/next');
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });
    expect(
      await diagnostics.http('http://127.0.0.1:${server.port}'),
      contains('HTTP 302'),
    );
    await expectLater(
      diagnostics.http('file:///private'),
      throwsFormatException,
    );
  });
}

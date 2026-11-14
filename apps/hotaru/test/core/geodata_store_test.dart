import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/geodata.dart';
import 'package:hotaru/core/geodata_store.dart';
import 'package:hotaru/core/routed_http.dart';

import 'sing_box/support/geodata_fixture.dart';

class _Transport implements CoreRoutedHttp {
  int calls = 0;
  int closed = 0;
  @override
  Future<T> withRoutedClient<T>(
    Future<T> Function(HttpClient) action, {
    String? outbound,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    calls++;
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      return await action(client).timeout(timeout);
    } finally {
      client.close(force: true);
      closed++;
    }
  }
}

void main() {
  late Directory directory;
  late HttpServer server;
  late _Transport transport;
  late CoreGeoDataStore store;
  var reads = 0;
  var status = 200;
  var malformed = false;
  var oversized = false;
  Completer<void>? held;
  final request = CoreGeoRequest.parse(CoreGeoKind.site, 'fixture')!;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hotaru-geodata-');
    addTearDown(() => directory.delete(recursive: true));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    transport = _Transport();
    store = CoreGeoDataStore(home: directory.path, transport: transport);
    reads = 0;
    status = 200;
    malformed = false;
    oversized = false;
    held = null;
    server.listen((received) async {
      reads++;
      await held?.future;
      received.response.statusCode = status;
      if (received.uri.path == '/redirect') {
        received.response.statusCode = 302;
        received.response.headers.set('location', '/payload');
      } else if (oversized) {
        final socket = await received.response.detachSocket(
          writeHeaders: false,
        );
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Length: ${CoreGeoDecoder.maxBytes + 1}\r\nConnection: close\r\n\r\n',
        );
        await socket.flush();
        await socket.close();
        return;
      } else {
        received.response.add(
          malformed
              ? [0]
              : geoDatabase('fixture', [geoDomain(3, 'example.com')]),
        );
      }
      await received.response.close();
    });
  });

  Map<String, String> urls([String path = '/payload']) => {
    'geosite': 'http://127.0.0.1:${server.port}$path',
  };

  test(
    'missing data downloads once, validates and persists across store recreation',
    () async {
      final first = await store.resolve([request], urls: urls('/redirect'));
      expect(first[request.key]!.set.domains, ['example.com']);
      expect(reads, 2);
      final rebuilt = CoreGeoDataStore(
        home: directory.path,
        transport: transport,
      );
      expect((await rebuilt.resolve([request], urls: urls('/redirect'))).keys, [
        request.key,
      ]);
      expect(reads, 2);
      expect(transport.closed, 1);
      expect(
        await File(await store.path('GEOSITE', urls('/redirect'))).exists(),
        isTrue,
      );
    },
  );

  test(
    'failed refresh keeps the previous accepted bytes and concurrent refreshes coalesce',
    () async {
      await store.resolve([request], urls: urls());
      final path = await store.path('GEOSITE', urls());
      final original = await File(path).readAsBytes();
      malformed = true;
      await expectLater(
        store.update('GEOSITE', urls: urls(), requests: [request]),
        throwsFormatException,
      );
      expect(await File(path).readAsBytes(), original);
      malformed = false;
      held = Completer<void>();
      final first = store.update('GEOSITE', urls: urls(), requests: [request]);
      final second = store.update('GEOSITE', urls: urls(), requests: [request]);
      while (reads < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      held!.complete();
      await Future.wait([first, second]);
      expect(reads, 3);
    },
  );

  test(
    'source URLs remain isolated and a declared oversized response never becomes a cache',
    () async {
      await store.resolve([request], urls: urls());
      final first = await store.path('GEOSITE', urls());
      final second = await store.path('GEOSITE', urls('/other'));
      expect(second, isNot(first));
      oversized = true;
      await expectLater(
        store.resolve([request], urls: urls('/other')),
        throwsA(anything),
      );
      expect(await File(second).exists(), isFalse);
      expect(await File(first).exists(), isTrue);
      expect(transport.closed, 2);
    },
  );

  test(
    'cache parent links cannot create directories outside the selected home',
    () async {
      if (Platform.isWindows) return;
      final outside = await Directory.systemTemp.createTemp(
        'hotaru-geo-outside-',
      );
      addTearDown(() => outside.delete(recursive: true));
      await Link('${directory.path}/providers').create(outside.path);
      await expectLater(store.path('GEOSITE', urls()), throwsA(anything));
      expect(await outside.list().toList(), isEmpty);
    },
  );

  test('LAN needs no database and cache symlinks are never followed', () async {
    final lan = CoreGeoRequest.parse(CoreGeoKind.ip, 'lan')!;
    expect((await store.resolve([lan])).keys, [lan.key]);
    expect(transport.calls, 0);
    if (Platform.isWindows) return;
    final path = await store.path('GEOSITE', urls());
    final outside = await File(
      '${directory.path}/outside',
    ).writeAsBytes(geoDatabase('fixture', [geoDomain(3, 'outside.invalid')]));
    await Link(path).create(outside.path);
    await expectLater(
      store.resolve([request], urls: urls()),
      throwsA(anything),
    );
    expect(transport.calls, 0);
  });
}

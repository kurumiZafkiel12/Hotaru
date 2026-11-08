import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/dns.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/runtime_options.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';
import 'package:hotaru/core/sing_box/host_events.dart';

final class _Reader {
  final StreamIterator<List<int>> stream;
  List<int> _chunk = const [];
  int _offset = 0;

  _Reader(Socket socket) : stream = StreamIterator(socket);

  Future<List<int>> take(int count) async {
    final bytes = <int>[];
    while (bytes.length < count) {
      if (_offset == _chunk.length) {
        if (!await stream.moveNext().timeout(const Duration(seconds: 5))) {
          throw const SocketException('Fixture closed before response');
        }
        _chunk = stream.current;
        _offset = 0;
      }
      bytes.add(_chunk[_offset++]);
    }
    return bytes;
  }
}

CoreProfileSpec _profile({
  CoreRuntimeOptions runtime = const CoreRuntimeOptions(),
}) => CoreProfileSpec(
  nodes: const [CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct)],
  selectors: [],
  finalOutbound: 'direct',
  runtime: runtime,
  dns: CoreDnsSpec(
    servers: const [
      CoreDnsServerSpec(tag: 'local', protocol: CoreDnsProtocol.local),
    ],
    finalServer: 'local',
  ),
);

void main() {
  test(
    'runtime options compile and survive pause/resume without exposing private control',
    () async {
      final settings = CoreListenerSpec(
        mixedPort: 17890,
        controllerPort: 19090,
        secret: 'private-fixture',
        inbound: CoreInboundOptions(
          listen: '0.0.0.0',
          users: const [CoreLocalCredential('alice', 'first:second')],
          httpPort: 17891,
          socksPort: 17892,
        ),
        tun: CoreTunSpec(
          interfaceName: 'fixture',
          addresses: ['172.19.0.1/30'],
          autoRoute: true,
          mtu: 1400,
          routes: ['0.0.0.0/0'],
          excludedRoutes: ['192.168.0.0/16'],
        ),
      );
      final profile = _profile(
        runtime: const CoreRuntimeOptions(
          logLevel: 'warning',
          findProcess: true,
          defaultInterface: 'Ethernet 2',
          resolveIpv6: false,
          tcpKeepAliveSeconds: 15,
          tcpKeepAliveIntervalSeconds: 30,
        ),
      );
      final builder = SingBoxConfigBuilder();
      final built = await builder.build(profile, settings);
      expect(built.issues, isEmpty);
      final doc = jsonDecode(built.json!);
      expect(doc['log'], {'level': 'warn'});
      expect(doc['route']['find_process'], isTrue);
      expect(doc['route']['default_interface'], 'Ethernet 2');
      expect(doc['route']['default_domain_resolver'], {
        'server': 'local',
        'strategy': 'ipv4_only',
      });
      expect(
        doc['inbounds'].take(3).map((dynamic entry) => entry['listen']),
        everyElement('0.0.0.0'),
      );
      expect(doc['inbounds'].last['mtu'], 1400);
      expect(doc['inbounds'].last['route_address'], ['0.0.0.0/0']);
      expect(doc['inbounds'].last['route_exclude_address'], ['192.168.0.0/16']);
      expect(
        doc['experimental']['clash_api']['external_controller'],
        '127.0.0.1:19090',
      );
      expect(doc['outbounds'][0]['tcp_keep_alive'], '15s');
      expect(doc['outbounds'][0]['tcp_keep_alive_interval'], '30s');
      final quiet = settings.withInbounds(false);
      expect(quiet.inbound, same(settings.inbound));
      final idle = await builder.build(profile, quiet);
      expect(jsonDecode(idle.json!)['inbounds'], isEmpty);
      final resumed = quiet.withRuntime(
        enabled: true,
        mode: CoreRoutingMode.direct,
        globalSelection: null,
      );
      expect(resumed.inbound, same(settings.inbound));
      expect(resumed.tun, same(settings.tun));
    },
  );

  test(
    'invalid credentials, addresses, ports, routes and runtime options cannot be applied',
    () async {
      final builder = SingBoxConfigBuilder();
      for (final inbound in [
        CoreInboundOptions(listen: 'not-an-ip'),
        CoreInboundOptions(httpPort: 17890),
        CoreInboundOptions(httpPort: 19090),
        CoreInboundOptions(httpPort: 15353),
        CoreInboundOptions(httpPort: 70000),
        CoreInboundOptions(httpPort: 17891, socksPort: 17891),
        CoreInboundOptions(
          users: const [
            CoreLocalCredential('alice', 'one'),
            CoreLocalCredential('alice', 'two'),
          ],
        ),
        CoreInboundOptions(users: const [CoreLocalCredential('', 'private')]),
        CoreInboundOptions(
          users: const [CoreLocalCredential('alice', 'private\nheader')],
        ),
      ]) {
        final result = await builder.build(
          _profile(),
          CoreListenerSpec(
            mixedPort: 17890,
            controllerPort: 19090,
            secret: 'fixture',
            inbound: inbound,
            dnsPort: 15353,
          ),
        );
        expect(result.json, isNull);
      }
      final invalid = await builder.build(
        _profile(
          runtime: const CoreRuntimeOptions(
            logLevel: 'unknown',
            defaultInterface: 'private\nheader',
            tcpKeepAliveSeconds: -1,
          ),
        ),
        CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
          tun: CoreTunSpec(
            interfaceName: 'fixture',
            addresses: ['172.19.0.1/30'],
            autoRoute: true,
            mtu: 0,
            routes: ['invalid'],
            excludedRoutes: ['also-invalid'],
          ),
        ),
      );
      expect(
        invalid.issues.map((issue) => issue.code),
        containsAll([
          'invalid_log_level',
          'invalid_default_interface',
          'invalid_tcp_keep_alive',
          'invalid_tun_mtu',
          'invalid_tun_routes',
        ]),
      );
      final noResolver = await builder.build(
        CoreProfileSpec(
          nodes: const [
            CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
          ],
          selectors: [],
          finalOutbound: 'direct',
          runtime: const CoreRuntimeOptions(resolveIpv6: false),
        ),
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(
        noResolver.issues.single.code,
        'dns_required_for_ip_family_policy',
      );
    },
  );

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlled = Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  test(
    'real mixed/HTTP/SOCKS authentication protects forwarding while control uses its own secret',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-runtime-options-',
      );
      final reserved = <ServerSocket>[];
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var receipts = 0;
      origin.listen((request) async {
        receipts++;
        request.response.write('authenticated-fixture-receipt');
        await request.response.close();
      });
      Process? process;
      final output = <String>[];
      final client = HttpClient();
      try {
        Future<int> port() async {
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          reserved.add(server);
          return server.port;
        }

        final mixed = await port();
        final http = await port();
        final socks = await port();
        final api = await port();
        final built = await SingBoxConfigBuilder().build(
          _profile(
            runtime: const CoreRuntimeOptions(
              logLevel: 'silent',
              findProcess: true,
              resolveIpv6: false,
              tcpKeepAliveSeconds: 15,
              tcpKeepAliveIntervalSeconds: 30,
            ),
          ),
          CoreListenerSpec(
            mixedPort: mixed,
            controllerPort: api,
            secret: 'controller-fixture',
            inbound: CoreInboundOptions(
              httpPort: http,
              socksPort: socks,
              users: const [CoreLocalCredential('alice', 'first:second')],
            ),
          ),
        );
        expect(built.issues, isEmpty);
        final config = await File(
          '${directory.path}/config.json',
        ).writeAsString(built.json!);
        final checked = await Process.run(binary!, [
          'check',
          '-c',
          config.path,
        ]);
        expect(checked.exitCode, 0, reason: '${checked.stderr}');
        for (final server in reserved) {
          await server.close();
        }
        process = await Process.start(binary, [
          'run',
          '-c',
          config.path,
          if (controlled) '--stdio-control',
        ]);
        final host = SingBoxHostEvents(process.pid);
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              output.add(line);
              if (controlled) host.add(line);
            });
        process.stderr.transform(utf8.decoder).listen(output.add);
        if (controlled) await host.ready.timeout(const Duration(seconds: 10));
        var ready = false;
        for (var i = 0; i < 60; i++) {
          try {
            final socket = await Socket.connect(
              InternetAddress.loopbackIPv4,
              api,
            );
            socket.destroy();
            ready = true;
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        expect(ready, isTrue, reason: output.join());
        for (final port in [mixed, http]) {
          final unauthenticated = await Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
          );
          final reader = _Reader(unauthenticated);
          try {
            unauthenticated.add(
              ascii.encode(
                'CONNECT 127.0.0.1:${origin.port} HTTP/1.1\r\nHost: localhost\r\nProxy-Connection: keep-alive\r\n\r\n',
              ),
            );
            await unauthenticated.flush();
            expect(ascii.decode(await reader.take(12)), 'HTTP/1.1 407');
          } finally {
            unauthenticated.destroy();
            await reader.stream.cancel();
          }
          client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
          client.addProxyCredentials(
            '127.0.0.1',
            port,
            'sing-box',
            HttpClientBasicCredentials('alice', 'first:second'),
          );
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/receipt'),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          expect(
            await response.transform(utf8.decoder).join(),
            'authenticated-fixture-receipt',
          );
        }
        expect(receipts, 2);
        for (final authorized in [false, true]) {
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            socks,
          );
          final reader = _Reader(socket);
          try {
            socket.add([5, 1, 2]);
            await socket.flush();
            expect(await reader.take(2), [5, 2]);
            final password = ascii.encode(
              authorized ? 'first:second' : 'wrong',
            );
            socket.add([
              1,
              5,
              ...ascii.encode('alice'),
              password.length,
              ...password,
            ]);
            try {
              await socket.flush();
              expect(await reader.take(2), [1, authorized ? 0 : 1]);
            } on SocketException catch (error) {
              // Pinned upstream resets failed handshakes with SetLinger(0).
              if (authorized ||
                  ![54, 104, 10054].contains(error.osError?.errorCode)) {
                rethrow;
              }
            }
            if (!authorized) continue;
            socket.add([
              5,
              1,
              0,
              1,
              127,
              0,
              0,
              1,
              origin.port >> 8,
              origin.port & 255,
            ]);
            await socket.flush();
            final reply = await reader.take(4);
            expect(reply.take(3), [5, 0, 0]);
            await reader.take(reply[3] == 1 ? 6 : 18);
            socket.add(
              ascii.encode(
                'GET /receipt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
              ),
            );
            await socket.flush();
            final body = StringBuffer();
            while (!body.toString().contains('authenticated-fixture-receipt')) {
              body.writeCharCode((await reader.take(1)).single);
            }
          } finally {
            socket.destroy();
            await reader.stream.cancel();
          }
        }
        expect(receipts, 3);
        client.findProxy = (_) => 'DIRECT';
        for (final authorized in [false, true]) {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$api/version'),
          );
          request.headers.set(
            HttpHeaders.authorizationHeader,
            authorized
                ? 'Bearer controller-fixture'
                : 'Basic ${base64Encode(ascii.encode('alice:first:second'))}',
          );
          final response = await request.close();
          expect(response.statusCode, authorized ? 200 : 401);
          await response.drain<void>();
        }
      } finally {
        client.close(force: true);
        if (process != null) {
          if (controlled) {
            process.stdin.writeln('stop');
            await process.stdin.flush();
            await process.stdin.close();
            expect(
              await process.exitCode.timeout(const Duration(seconds: 5)),
              0,
            );
          } else {
            process.kill();
            await process.exitCode.timeout(const Duration(seconds: 5));
          }
        }
        for (final server in reserved) {
          await server.close();
        }
        await origin.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX for native listener verification'
        : false,
  );
}

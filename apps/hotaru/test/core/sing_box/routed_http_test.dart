import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/runtime_options.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/outbound_http.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/sing_box/desktop_core.dart';
import 'package:hotaru/core/sing_box/routed_http.dart';
import 'package:mocktail/mocktail.dart';

import '../desktop/fakes.dart';

class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

class _Adapter extends Mock implements CoreAdapter, CoreOutboundHttp {
  final int proxy;
  String direct = '';
  String? requested;
  Future<void>? gate;
  final clients = <HttpClient>[];

  _Adapter(this.proxy);

  @override
  Future<T> withOutboundClient<T>(
    String outbound,
    Future<T> Function(HttpClient) action, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    requested = outbound;
    await gate;
    final client = HttpClient()
      ..findProxy = (_) =>
          outbound == direct ? 'DIRECT' : 'PROXY 127.0.0.1:$proxy';
    clients.add(client);
    try {
      return await action(client);
    } finally {
      client.close(force: true);
    }
  }
}

class _Binding implements SingBoxConfigurationBinding {
  @override
  AcceptedSingBoxConfig current;
  final CoreAdapter adapter;
  _Binding(this.current, this.adapter);
  @override
  CoreAdapter createAdapter() => adapter;
  @override
  Future<CoreLifecycleResult> apply(AcceptedSingBoxConfig configuration) =>
      throw UnimplementedError();
}

DesktopCoreRunning _running(String id) => DesktopCoreRunning(
  DesktopCoreSession(
    sessionId: id,
    connectionGeneration: 1,
    lease: FakeProcessLease(
      owner: CoreProcessOwner.direct,
      pid: 4321,
      sessionId: id,
    ),
  ),
);

void main() {
  late HttpServer origin;
  late HttpServer gatewayA;
  late HttpServer gatewayB;
  late _Lifecycle lifecycle;
  late _Adapter adapter;
  late _Binding binding;
  late SingBoxDesktopCore core;
  late SingBoxRoutedHttp transport;
  late StreamController<DesktopCoreState> changes;
  late DesktopCoreState state;
  var origins = 0;
  var a = 0;
  var b = 0;
  final forwarding = <HttpClient>[];

  Future<AcceptedSingBoxConfig> configuration({
    bool enabled = true,
    int id = 7,
  }) async {
    final preparer = SingBoxConfigPreparer();
    final result = await preparer.prepare(
      profileId: id,
      import: () async => CoreConfigImportResult(
        profile: CoreProfileSpec(
          nodes: const [
            CoreNodeSpec(tag: 'A', protocol: CoreNodeProtocol.direct),
          ],
          selectors: [],
          finalOutbound: 'A',
        ),
        issues: [],
      ),
      listeners: CoreListenerSpec(
        mixedPort: gatewayB.port,
        controllerPort: 19090,
        secret: 'controller',
        inboundsEnabled: enabled,
        inbound: CoreInboundOptions(
          users: const [CoreLocalCredential('fixture', 'pass:part')],
        ),
      ),
    );
    return preparer.approve(result.candidate!);
  }

  setUp(() async {
    origins = a = b = 0;
    forwarding.clear();
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      origins++;
      expect(request.headers.value('proxy-authorization'), isNull);
      request.response.write('origin-receipt');
      await request.response.close();
    });
    gatewayA = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    gatewayB = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    void forward(HttpServer server, bool authenticated) {
      server.listen((request) async {
        if (authenticated &&
            request.headers.value('proxy-authorization') !=
                'Basic ${base64Encode(utf8.encode('fixture:pass:part'))}') {
          request.response.statusCode = 407;
          request.response.headers.set(
            'proxy-authenticate',
            'Basic realm="sing-box"',
          );
          await request.response.close();
          return;
        }
        if (authenticated) {
          b++;
        } else {
          a++;
        }
        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        forwarding.add(client);
        try {
          final outgoing = await client.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}${request.uri.path}'),
          );
          request.response.add(
            await (await outgoing.close()).fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            ),
          );
          await request.response.close();
        } finally {
          client.close(force: true);
        }
      });
    }

    forward(gatewayA, false);
    forward(gatewayB, true);
    lifecycle = _Lifecycle();
    adapter = _Adapter(gatewayA.port);
    changes = StreamController.broadcast();
    state = _running('one');
    when(() => lifecycle.state).thenAnswer((_) => state);
    when(() => lifecycle.states).thenAnswer((_) => changes.stream);
    when(() => lifecycle.close()).thenAnswer(
      (_) async => const CoreLifecycleResult(
        revision: 1,
        outcome: CoreLifecycleOutcome.applied,
      ),
    );
    when(() => adapter.close()).thenAnswer((_) async {});
    final accepted = await configuration();
    adapter.direct = accepted.directOutbound;
    binding = _Binding(accepted, adapter);
    core = SingBoxDesktopCore.withConfiguration(
      lifecycle: lifecycle,
      configuration: binding,
    );
    transport = SingBoxRoutedHttp(core);
  });
  tearDown(() async {
    await transport.close();
    await core.close();
    await changes.close();
    for (final client in forwarding) {
      client.close(force: true);
    }
    await gatewayA.close(force: true);
    await gatewayB.close(force: true);
    await origin.close(force: true);
  });

  Future<String> request(HttpClient client) async {
    final pending = await client.getUrl(
      Uri.parse('http://127.0.0.1:${origin.port}/proof'),
    );
    return utf8.decoder.bind(await pending.close()).join();
  }

  test(
    'default traffic follows the committed authenticated mixed gateway; named and DIRECT routes remain distinct',
    () async {
      expect(await transport.withRoutedClient(request), 'origin-receipt');
      expect((origins, a, b), (1, 0, 1));
      expect(
        await transport.withRoutedClient(request, outbound: 'A'),
        'origin-receipt',
      );
      expect(adapter.requested, 'A');
      expect((origins, a, b), (2, 1, 1));
      expect(
        await transport.withRoutedClient(request, outbound: 'DIRECT'),
        'origin-receipt',
      );
      expect(adapter.requested, binding.current.directOutbound);
      expect((origins, a, b), (3, 1, 1));
    },
  );

  test(
    'paused data uses physical direct only when the committed session says it is paused',
    () async {
      binding.current = await configuration(enabled: false);
      expect(await transport.withRoutedClient(request), 'origin-receipt');
      expect(
        await transport.withRoutedClient(request, outbound: 'DIRECT'),
        'origin-receipt',
      );
      expect((origins, a, b), (2, 0, 0));
      await expectLater(
        transport.withRoutedClient(request, outbound: 'A'),
        throwsA(isA<CoreAdapterException>()),
      );
      state = const DesktopCoreIdle();
      await expectLater(
        transport.withRoutedClient(request),
        throwsA(isA<CoreAdapterException>()),
      );
      expect((origins, a, b), (2, 0, 0));
    },
  );

  test(
    'a retained client cannot issue requests once its scope has returned',
    () async {
      late HttpClient retained;
      await transport.withRoutedClient((client) async {
        retained = client;
      });
      await expectLater(
        Future.sync(
          () => retained.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/late'),
          ),
        ),
        throwsA(anyOf(isA<StateError>(), isA<HttpException>())),
      );
      expect(origins, 0);
    },
  );

  test(
    'callback errors preserve their cause and still close the scoped client',
    () async {
      late HttpClient retained;
      await expectLater(
        transport.withRoutedClient((client) async {
          retained = client;
          throw StateError('callback failed');
        }),
        throwsStateError,
      );
      await expectLater(
        Future.sync(
          () => retained.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/late'),
          ),
        ),
        throwsA(anyOf(isA<StateError>(), isA<HttpException>())),
      );
      expect(origins, 0);
    },
  );

  test(
    'session replacement cancels an unfinished callback without waiting for it',
    () async {
      final entered = Completer<void>();
      final lateValue = Completer<String>();
      final pending = transport.withRoutedClient((client) {
        entered.complete();
        return lateValue.future;
      });
      await entered.future;
      state = _running('two');
      changes.add(state);
      await expectLater(
        pending.timeout(const Duration(seconds: 2)),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      lateValue.complete('stale');
      expect(await transport.withRoutedClient(request), 'origin-receipt');
      expect((origins, a, b), (1, 0, 1));
    },
  );

  test(
    'configuration replacement in the same process also rejects old results',
    () async {
      final entered = Completer<void>();
      final lateValue = Completer<String>();
      final pending = transport.withRoutedClient((client) {
        entered.complete();
        return lateValue.future;
      });
      await entered.future;
      binding.current = await configuration(id: 8);
      changes.add(state);
      await expectLater(
        pending,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'session_changed',
          ),
        ),
      );
      lateValue.complete('old');
    },
  );

  test(
    'timeout cannot call an action after a delayed outbound binding eventually returns',
    () async {
      final delayed = Completer<void>();
      adapter.gate = delayed.future;
      var called = false;
      await expectLater(
        transport.withRoutedClient(
          (client) async {
            called = true;
            return request(client);
          },
          outbound: 'A',
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'timeout',
          ),
        ),
      );
      delayed.complete();
      await Future<void>.delayed(Duration.zero);
      expect(called, isFalse);
      expect(origins, 0);
      await expectLater(
        Future.sync(
          () => adapter.clients.single.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/late'),
          ),
        ),
        throwsA(anyOf(isA<StateError>(), isA<HttpException>())),
      );
    },
  );

  test(
    'terminal close immediately invalidates outstanding work and never starts the process',
    () async {
      final entered = Completer<void>();
      final lateValue = Completer<String>();
      final pending = transport.withRoutedClient((client) {
        entered.complete();
        return lateValue.future;
      });
      final rejected = expectLater(
        pending,
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'closed',
          ),
        ),
      );
      await entered.future;
      await transport.close();
      await rejected;
      lateValue.complete('late');
      await expectLater(
        transport.withRoutedClient(request),
        throwsA(isA<CoreAdapterException>()),
      );
      verifyNever(() => lifecycle.start());
    },
  );
}

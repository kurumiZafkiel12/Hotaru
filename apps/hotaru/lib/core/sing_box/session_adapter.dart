import 'dart:async';
import 'dart:io';

import '../adapter.dart';
import '../logs.dart';
import '../outbound_http.dart';
import '../telemetry.dart';
import '../routing_mode.dart';
import '../maintenance.dart';
import '../desktop/lifecycle.dart';
import '../desktop/model.dart';

final class SessionCoreAdapter
    implements
        CoreAdapter,
        CoreLogSource,
        CoreOutboundHttpClients,
        CoreTelemetry,
        CoreRoutingModes,
        CoreRuntimeMaintenance,
        CoreConnectionMaintenance {
  final DesktopCoreLifecycleController lifecycle;
  final CoreAdapter Function() _factory;
  late final StreamSubscription<DesktopCoreState> _subscription;
  CoreAdapter? _adapter;
  String? _sessionId;
  bool _closed = false;
  Future<void>? _closing;
  Future<void> _clientCleanup = Future.value();

  SessionCoreAdapter({
    required this.lifecycle,
    required CoreAdapter Function() factory,
  }) : _factory = factory {
    _subscription = lifecycle.states.listen((_) {
      final state = lifecycle.state;
      if (state is! DesktopCoreRunning ||
          state.session.sessionId != _sessionId) {
        _invalidate();
      }
    });
  }

  void _invalidate() {
    final adapter = _adapter;
    _adapter = null;
    _sessionId = null;
    if (adapter != null) {
      final cleanup = adapter.close();
      _clientCleanup = Future.wait([_clientCleanup, cleanup]).then((_) {});
      unawaited(_clientCleanup.catchError((Object _) {}));
    }
  }

  bool _sameSession(String id) {
    final state = lifecycle.state;
    return !_closed &&
        state is DesktopCoreRunning &&
        state.session.sessionId == id;
  }

  Future<T> _invoke<T>(Future<T> Function(CoreAdapter adapter) action) async {
    if (_closed) throw const CoreAdapterException('closed');
    final state = lifecycle.state;
    if (state is! DesktopCoreRunning) {
      throw const CoreAdapterException('core_not_running');
    }
    final id = state.session.sessionId;
    if (_sessionId != id) {
      _invalidate();
      _adapter = _factory();
      _sessionId = id;
    }
    try {
      final value = await action(_adapter!);
      if (!_sameSession(id)) {
        throw const CoreAdapterException('session_changed');
      }
      return value;
    } catch (_) {
      if (!_sameSession(id)) {
        throw const CoreAdapterException('session_changed');
      }
      rethrow;
    }
  }

  @override
  Stream<CoreLogMessage> logs() => Stream.multi((controller) {
    final subscription =
        Stream.fromFuture(
              _invoke((adapter) async {
                if (adapter is! CoreLogSource) {
                  throw const CoreAdapterException('logs_unavailable');
                }
                return (_sessionId!, adapter as CoreLogSource);
              }),
            )
            .asyncExpand(
              (binding) =>
                  binding.$2.logs().takeWhile((_) => _sameSession(binding.$1)),
            )
            .listen(
              controller.addSync,
              onError: controller.addErrorSync,
              onDone: controller.closeSync,
            );
    controller.onCancel = () => subscription.cancel();
    controller.onPause = subscription.pause;
    controller.onResume = subscription.resume;
  });

  @override
  Future<List<CoreOutbound>> outbounds() =>
      _invoke((adapter) => adapter.outbounds());

  @override
  Future<void> selectOutbound(String group, String outbound) =>
      _invoke((adapter) => adapter.selectOutbound(group, outbound));

  @override
  Future<Duration> delay(String outbound, Uri target, Duration timeout) =>
      _invoke((adapter) => adapter.delay(outbound, target, timeout));

  @override
  Future<CoreConnections> connections() =>
      _invoke((adapter) => adapter.connections());

  @override
  Future<void> closeConnection(String id) =>
      _invoke((adapter) => adapter.closeConnection(id));

  @override
  Future<CoreRoutingMode> routingMode() => _invoke((adapter) {
    if (adapter is! CoreRoutingModes) {
      throw const CoreAdapterException('routing_modes_unavailable');
    }
    return (adapter as CoreRoutingModes).routingMode();
  });

  @override
  Future<void> setRoutingMode(CoreRoutingMode mode) => _invoke((adapter) {
    if (adapter is! CoreRoutingModes) {
      throw const CoreAdapterException('routing_modes_unavailable');
    }
    return (adapter as CoreRoutingModes).setRoutingMode(mode);
  });

  @override
  Future<CoreTelemetrySnapshot> telemetry() => _invoke((adapter) {
    if (adapter is! CoreTelemetry) {
      throw const CoreAdapterException('telemetry_unavailable');
    }
    return (adapter as CoreTelemetry).telemetry();
  });

  @override
  Future<void> closeConnections() => _invoke((adapter) {
    if (adapter is! CoreConnectionMaintenance) {
      throw const CoreAdapterException('connection_maintenance_unavailable');
    }
    return (adapter as CoreConnectionMaintenance).closeConnections();
  });

  @override
  Future<void> clearDnsCache() => _invoke((adapter) {
    if (adapter is! CoreConnectionMaintenance) {
      throw const CoreAdapterException('connection_maintenance_unavailable');
    }
    return (adapter as CoreConnectionMaintenance).clearDnsCache();
  });

  @override
  Future<void> collectMemory() => _invoke((adapter) {
    if (adapter is! CoreRuntimeMaintenance) {
      throw const CoreAdapterException('runtime_maintenance_unavailable');
    }
    return (adapter as CoreRuntimeMaintenance).collectMemory();
  });

  @override
  Future<void> resetDnsConnections() => _invoke((adapter) {
    if (adapter is! CoreRuntimeMaintenance) {
      throw const CoreAdapterException('runtime_maintenance_unavailable');
    }
    return (adapter as CoreRuntimeMaintenance).resetDnsConnections();
  });

  @override
  Future<T> withOutboundClient<T>(
    String outbound,
    Future<T> Function(HttpClient client) action, {
    Duration timeout = const Duration(minutes: 2),
  }) => _invoke((adapter) {
    if (adapter is! CoreOutboundHttp) {
      throw const CoreAdapterException('outbound_http_unavailable');
    }
    return (adapter as CoreOutboundHttp).withOutboundClient(
      outbound,
      action,
      timeout: timeout,
    );
  });

  @override
  Future<T> withOutboundClients<T>(
    String outbound,
    Future<T> Function(CoreOutboundClients clients) action, {
    Duration timeout = const Duration(minutes: 2),
  }) => _invoke((adapter) {
    if (adapter is! CoreOutboundHttpClients) {
      throw const CoreAdapterException('outbound_http_unavailable');
    }
    final id = _sessionId!;
    return (adapter as CoreOutboundHttpClients).withOutboundClients(
      outbound,
      (clients) => action(
        CoreOutboundClients(
          chain: clients.chain,
          createClient: () {
            if (!_sameSession(id)) {
              throw const CoreAdapterException('session_changed');
            }
            return clients.createClient();
          },
        ),
      ),
      timeout: timeout,
    );
  });

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _invalidate();
    await _subscription.cancel();
    await _clientCleanup;
  }
}

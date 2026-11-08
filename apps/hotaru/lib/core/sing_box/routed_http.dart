import 'dart:async';
import 'dart:io';

import '../adapter.dart';
import '../desktop/model.dart';
import '../outbound_http.dart';
import '../routed_http.dart';
import 'config_preparation.dart';
import 'desktop_core.dart';

final class SingBoxRoutedHttp implements CoreRoutedHttp {
  final SingBoxDesktopCore core;
  final Set<_HttpScope> _scopes = {};
  late final StreamSubscription<DesktopCoreState> _states;
  bool _closed = false;

  SingBoxRoutedHttp(this.core) {
    _states = core.lifecycle.states.listen((_) {
      for (final scope in _scopes) {
        if (!_current(scope)) {
          scope.invalidate(_closed ? 'closed' : 'session_changed');
        }
      }
    });
  }

  bool _current(_HttpScope scope) {
    final state = core.lifecycle.state;
    return !_closed &&
        state is DesktopCoreRunning &&
        state.session.sessionId == scope.session &&
        identical(core.configuration, scope.configuration);
  }

  void _check(_HttpScope scope) {
    if (scope.failure case final failure?) throw CoreAdapterException(failure);
    if (!_current(scope)) {
      throw CoreAdapterException(_closed ? 'closed' : 'session_changed');
    }
  }

  @override
  Future<T> withRoutedClient<T>(
    Future<T> Function(HttpClient client) action, {
    String? outbound,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError('Positive timeout required');
    }
    if (_closed) throw const CoreAdapterException('closed');
    final state = core.lifecycle.state;
    final configuration = core.configuration;
    if (state is! DesktopCoreRunning || configuration == null) {
      throw const CoreAdapterException('applied_profile_unavailable');
    }
    final scope = _HttpScope(state.session.sessionId, configuration);
    _scopes.add(scope);
    Future<T> execute() async {
      final enabled = configuration.listeners.inboundsEnabled;
      if (outbound != null && (enabled || outbound != 'DIRECT')) {
        if (!enabled) {
          throw const CoreAdapterException('scoped_client_unavailable');
        }
        final adapter = core.adapter;
        if (adapter is! CoreOutboundHttp) {
          throw const CoreAdapterException('outbound_http_unavailable');
        }
        final target = outbound == 'DIRECT'
            ? configuration.directOutbound
            : outbound;
        return (adapter as CoreOutboundHttp).withOutboundClient(target, (
          client,
        ) {
          scope.attach(client);
          _check(scope);
          return action(client);
        }, timeout: timeout);
      }
      final client = HttpClient();
      scope.attach(client);
      if (enabled) {
        final options = configuration.listeners.inbound;
        final listen = options?.listen ?? '127.0.0.1';
        final host = switch (listen) {
          '0.0.0.0' => '127.0.0.1',
          '::' => '::1',
          _ => listen,
        };
        final proxy = host.contains(':') ? '[$host]' : host;
        final port = configuration.listeners.mixedPort;
        client.findProxy = (_) => 'PROXY $proxy:$port';
        final user = options?.users.firstOrNull;
        if (user != null) {
          client.addProxyCredentials(
            host,
            port,
            'sing-box',
            HttpClientBasicCredentials(user.username, user.password),
          );
        }
      } else {
        client.findProxy = (_) => 'DIRECT';
      }
      _check(scope);
      return action(client);
    }

    try {
      final result =
          await Future.any<T>([
            execute(),
            scope.invalidated.future.then<T>(
              (_) => throw CoreAdapterException(
                scope.failure ?? 'session_changed',
              ),
            ),
          ]).timeout(
            timeout,
            onTimeout: () {
              scope.invalidate('timeout');
              throw const CoreAdapterException('timeout');
            },
          );
      _check(scope);
      return result;
    } catch (_) {
      _check(scope);
      rethrow;
    } finally {
      _scopes.remove(scope);
      scope.finish();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final scope in _scopes) {
      scope.invalidate('closed');
    }
    await _states.cancel();
  }
}

final class _HttpScope {
  final String session;
  final AcceptedSingBoxConfig configuration;
  final Completer<void> invalidated = Completer<void>();
  HttpClient? client;
  String? failure;

  _HttpScope(this.session, this.configuration);

  void attach(HttpClient value) {
    client = value;
    if (failure != null) value.close(force: true);
  }

  void finish() {
    failure ??= 'http_scope_closed';
    client?.close(force: true);
  }

  void invalidate(String code) {
    failure ??= code;
    client?.close(force: true);
    if (!invalidated.isCompleted) invalidated.complete();
  }
}

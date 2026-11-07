import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../../models/models.dart';
import '../adapter.dart';
import '../desktop/model.dart';
import '../routing_mode.dart';
import 'config_preparation.dart';
import 'desktop_core.dart';

final class _Policy {
  final String sessionId;
  final CoreRoutingMode mode;
  final List<CoreOutbound> outbounds;
  final RouteSnapshot snapshot;

  const _Policy(this.sessionId, this.mode, this.outbounds, this.snapshot);
}

final class SingBoxUiRoutes {
  final SingBoxDesktopCore core;
  final void Function(RouteSnapshot) onChange;
  final void Function(Object, StackTrace) onError;
  final Duration interval;
  late final StreamSubscription<DesktopCoreState> _states;
  Future<void> _tail = Future.value();
  Future<void>? _polling;
  Future<void>? _closing;
  Timer? _timer;
  bool _watching = false;
  bool _closed = false;
  String? _sessionId;
  AcceptedSingBoxConfig? _configuration;
  String? _fingerprint;
  int _epoch = 0;
  int _version = 0;

  SingBoxUiRoutes({
    required this.core,
    required this.onChange,
    required this.onError,
    this.interval = const Duration(seconds: 1),
  }) {
    if (interval <= Duration.zero) {
      throw ArgumentError('Positive route interval required');
    }
    _states = core.lifecycle.states.listen((_) {
      _syncTimer();
      if (_watching && core.lifecycle.state is DesktopCoreRunning) _poll();
    });
  }

  RouteSnapshot get _snapshot =>
      RouteSnapshot(coreEpoch: _epoch, routeVersion: _version);

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _tail.then((_) {
      if (_closed) throw const CoreAdapterException('closed');
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  DesktopCoreRunning _running() {
    final state = core.lifecycle.state;
    if (state is! DesktopCoreRunning) {
      throw const CoreAdapterException('core_not_running');
    }
    return state;
  }

  Future<_Policy> _read() async {
    final session = _running().session.sessionId;
    final configuration = core.configuration;
    if (configuration == null) {
      throw const CoreAdapterException('applied_profile_unavailable');
    }
    final source = core.adapter;
    if (source is! CoreRoutingModes) {
      throw const CoreAdapterException('routing_modes_unavailable');
    }
    void check() {
      final state = core.lifecycle.state;
      if (_closed ||
          state is! DesktopCoreRunning ||
          state.session.sessionId != session ||
          !identical(core.configuration, configuration)) {
        throw const CoreAdapterException('session_changed');
      }
    }

    final mode = await (source as CoreRoutingModes).routingMode();
    check();
    final outbounds = await source.outbounds();
    check();
    if (await (source as CoreRoutingModes).routingMode() != mode) {
      throw const CoreAdapterException('route_changed');
    }
    check();
    final fingerprint = await _policyFingerprint(mode, outbounds);
    check();
    var changed = false;
    if (_sessionId != session || !identical(_configuration, configuration)) {
      _sessionId = session;
      _configuration = configuration;
      _epoch++;
      _version = 0;
      changed = true;
    } else if (_fingerprint != fingerprint) {
      _version++;
      changed = true;
    }
    _fingerprint = fingerprint;
    final snapshot = _snapshot;
    if (changed && _watching) {
      try {
        onChange(snapshot);
      } catch (error, trace) {
        onError(error, trace);
      }
    }
    return _Policy(session, mode, outbounds, snapshot);
  }

  static Future<String> _policyFingerprint(
    CoreRoutingMode mode,
    List<CoreOutbound> outbounds,
  ) => Isolate.run(() {
    final selected = outbounds.where((node) => node.selected != null).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              mode.name,
              for (final node in selected) [node.name, node.selected],
            ]),
          ),
        )
        .toString();
  });

  Future<RouteSnapshot> snapshot() =>
      _run(() async => (await _read()).snapshot);

  Future<RouteSnapshot> watch(bool watch) {
    _watching = watch && !_closed;
    _syncTimer();
    if (!_watching) return Future.value(_snapshot);
    return snapshot().whenComplete(_syncTimer);
  }

  Future<CoreRoutingMode> mode() => _run(() async => (await _read()).mode);

  Future<void> setMode(CoreRoutingMode mode) => _run(() async {
    final before = await _read();
    if (before.mode == mode) return;
    await (core.adapter as CoreRoutingModes).setRoutingMode(mode);
    final after = await _read();
    _checkMutation(before, after);
    if (after.mode != mode) throw const CoreAdapterException('route_changed');
  });

  Future<ChangeProxyResult> select(String group, String outbound) =>
      _run(() async {
        final before = await _read();
        final candidates = before.outbounds
            .where((node) => node.name == group)
            .toList();
        if (candidates.length != 1 ||
            candidates.single.type.toLowerCase() != 'selector' ||
            !candidates.single.members.contains(outbound)) {
          throw const CoreAdapterException('invalid_selection');
        }
        final previous = candidates.single.selected;
        if (previous != outbound) {
          await core.adapter.selectOutbound(group, outbound);
        }
        final after = previous == outbound ? before : await _read();
        _checkMutation(before, after);
        final selected = after.outbounds
            .where((node) => node.name == group)
            .toList();
        if (selected.length != 1 || selected.single.selected != outbound) {
          throw const CoreAdapterException('selection_changed');
        }
        return ChangeProxyResult(
          coreEpoch: after.snapshot.coreEpoch,
          routeVersion: after.snapshot.routeVersion,
          changed: previous != outbound,
        );
      });

  static void _checkMutation(_Policy before, _Policy after) {
    if (before.sessionId != after.sessionId ||
        before.snapshot.coreEpoch != after.snapshot.coreEpoch) {
      throw const CoreAdapterException('session_changed');
    }
  }

  void _syncTimer() {
    if (_closed || !_watching || core.lifecycle.state is! DesktopCoreRunning) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(interval, (_) => _poll());
    }
  }

  void _poll() {
    if (_closed || !_watching || _polling != null) return;
    _polling = _pollOnce().whenComplete(() => _polling = null);
  }

  Future<void> _pollOnce() async {
    try {
      await snapshot();
    } catch (error, trace) {
      if (!_closed && _watching) onError(error, trace);
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _watching = false;
    _syncTimer();
    await _states.cancel();
    await _tail;
  }
}

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
import 'runtime_configuration.dart';

final class _Policy {
  final String sessionId;
  final CoreRoutingMode mode;
  final List<CoreOutbound> outbounds;
  final RouteSnapshot snapshot;
  final AcceptedSingBoxConfig configuration;

  const _Policy(
    this.sessionId,
    this.mode,
    this.outbounds,
    this.snapshot,
    this.configuration,
  );
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
  _Policy? _lastPolicy;
  AcceptedSingBoxConfig? _requestedConfiguration;
  ({
    Future<AcceptedSingBoxConfig?> Function(
      AcceptedSingBoxConfig,
      List<CoreOutbound>,
    )
    prepare,
    bool preserveMode,
  })?
  _requestedUpdate;
  AcceptedSingBoxConfig? _lastSubmitted;
  bool? _requestedInbounds;
  int _configurationRevision = 0;
  int _applyingConfigurations = 0;
  final _configurationOperations = <Future<CoreLifecycleResult>>{};

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
    final policy = _Policy(session, mode, outbounds, snapshot, configuration);
    _lastPolicy = policy;
    return policy;
  }

  Future<CoreLifecycleResult> applyConfiguration(
    AcceptedSingBoxConfig configuration,
  ) {
    _requestedConfiguration = configuration;
    _requestedUpdate = null;
    return _requestConfiguration();
  }

  Future<CoreLifecycleResult> updateConfiguration(
    Future<AcceptedSingBoxConfig?> Function(
      AcceptedSingBoxConfig,
      List<CoreOutbound>,
    )
    update, {
    bool preserveMode = false,
  }) {
    _adoptCommittedConfiguration();
    _requestedUpdate = (prepare: update, preserveMode: preserveMode);
    return _requestConfiguration();
  }

  Future<bool> setInbounds(bool enabled) {
    _adoptCommittedConfiguration();
    _requestedInbounds = enabled;
    final committed = core.configuration;
    if (!_closed &&
        core.lifecycle.state is DesktopCoreRunning &&
        _configurationOperations.isEmpty &&
        committed?.listeners.inboundsEnabled == enabled &&
        (_requestedConfiguration == null ||
            identical(_requestedConfiguration, committed))) {
      return Future.value(true);
    }
    return _requestConfiguration().then((_) => true);
  }

  Future<CoreLifecycleResult> restart() {
    _adoptCommittedConfiguration();
    if (core.lifecycle.state is DesktopCoreRunning ||
        _configurationOperations.isNotEmpty) {
      return _requestConfiguration();
    }
    return core.restart();
  }

  void _adoptCommittedConfiguration() {
    if (_configurationOperations.isEmpty) {
      _requestedConfiguration = core.configuration;
      _requestedInbounds = core.configuration?.listeners.inboundsEnabled;
    }
  }

  Future<CoreLifecycleResult> _requestConfiguration() {
    if (_closed) return Future.error(const CoreAdapterException('closed'));
    final revision = ++_configurationRevision;
    final operation = _configure(revision);
    _configurationOperations.add(operation);
    operation.then<void>(
      (_) => _configurationOperations.remove(operation),
      onError: (Object _, StackTrace _) =>
          _configurationOperations.remove(operation),
    );
    return operation;
  }

  bool _configurationCurrent(int revision) =>
      !_closed && revision == _configurationRevision;

  CoreLifecycleResult _supersededConfiguration(int revision) =>
      CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.superseded,
      );

  Future<CoreLifecycleResult> _configure(int revision) async {
    try {
      final submitted = await _run(() async {
        if (!_configurationCurrent(revision)) return null;
        final before = _applyingConfigurations > 0 && _lastPolicy != null
            ? _lastPolicy!
            : await _read();
        if (!_configurationCurrent(revision)) return null;
        var base = _requestedConfiguration ?? before.configuration;
        final update = _requestedUpdate;
        if (update != null) {
          final updated = await update.prepare(base, before.outbounds);
          if (!_configurationCurrent(revision)) return null;
          if (updated == null) {
            throw const CoreAdapterException('configuration_review_cancelled');
          }
          base = updated;
        }
        final enabled =
            _requestedInbounds ??
            before.configuration.listeners.inboundsEnabled;
        final preserve = identical(base.profile, before.configuration.profile);
        final prepared = await prepareSingBoxRuntime(
          configuration: base,
          enabled: enabled,
          mode: preserve || update?.preserveMode == true
              ? before.mode
              : base.listeners.initialMode,
          outbounds: before.outbounds,
          preserveSelections: preserve,
        );
        if (!_configurationCurrent(revision)) return null;
        final committed = core.configuration;
        if (!identical(committed, before.configuration) &&
            !identical(committed, _lastSubmitted)) {
          throw const CoreAdapterException('session_changed');
        }
        _lastSubmitted = prepared;
        _applyingConfigurations++;
        final completion = Future.sync(() => core.applyConfiguration(prepared))
            .then<
              ({CoreLifecycleResult? result, Object? error, StackTrace? trace})
            >(
              (result) => (result: result, error: null, trace: null),
              onError: (Object error, StackTrace trace) =>
                  (result: null, error: error, trace: trace),
            );
        return (before: before, prepared: prepared, completion: completion);
      });
      if (submitted == null) return _supersededConfiguration(revision);
      final ({CoreLifecycleResult? result, Object? error, StackTrace? trace})
      outcome;
      try {
        outcome = await submitted.completion;
      } finally {
        _applyingConfigurations--;
      }
      if (!_configurationCurrent(revision)) {
        return _supersededConfiguration(revision);
      }
      if (outcome.error != null) {
        Error.throwWithStackTrace(outcome.error!, outcome.trace!);
      }
      final applied = outcome.result!;
      final prepared = submitted.prepared;
      final before = submitted.before;
      if (applied.outcome == CoreLifecycleOutcome.superseded) {
        _requestedUpdate = null;
        _requestedConfiguration = core.configuration;
        _requestedInbounds = core.configuration?.listeners.inboundsEnabled;
        return applied;
      }
      if (!identical(core.configuration, prepared)) {
        throw const CoreAdapterException('session_changed');
      }
      _requestedUpdate = null;
      _requestedConfiguration = prepared;
      _requestedInbounds = prepared.listeners.inboundsEnabled;
      final after = await snapshot();
      if (!_configurationCurrent(revision)) {
        return _supersededConfiguration(revision);
      }
      if (after.coreEpoch == before.snapshot.coreEpoch) {
        throw const CoreAdapterException('session_changed');
      }
      return applied;
    } catch (_) {
      if (!_configurationCurrent(revision)) {
        return _supersededConfiguration(revision);
      }
      _requestedUpdate = null;
      _requestedConfiguration = core.configuration;
      _requestedInbounds = core.configuration?.listeners.inboundsEnabled;
      rethrow;
    }
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

  Future<({ProbeResult result, RouteSnapshot snapshot, List<RouteHit> hits})>
  observeProbe(
    ProbeParams params,
    Future<ProbeResult> Function(ProbeParams) send,
  ) async {
    final before = await _run(_read);
    final result = await send(params);
    final after = await _run(_read);
    _checkMutation(before, after);
    final initial = await _evidence(before, result.chains, params.proxyName);
    final current = await _evidence(after, result.chains, params.proxyName);
    if (initial != current) throw const CoreAdapterException('route_changed');
    return (
      result: result,
      snapshot: after.snapshot,
      hits: initial == null
          ? const <RouteHit>[]
          : <RouteHit>[
              RouteHit(
                host: Uri.parse(params.url).authority,
                proxy: params.proxyName,
                exit: initial,
              ),
            ],
    );
  }

  Future<RouteCheck> check(CheckRoutesParams params) async {
    if (params.routes.length > 256 ||
        params.routes.any((route) => route.length > 128)) {
      throw const CoreAdapterException('invalid_route_bounds');
    }
    final policy = await _run(_read);
    final routes = params.routes;
    final selections = {
      for (final node in policy.outbounds) node.name: node.selected,
    };
    final epoch = policy.snapshot.coreEpoch;
    final mode = policy.mode.name;
    final held = await Isolate.run(
      () => [
        for (final route in routes)
          route.isNotEmpty &&
              route.every((hit) {
                if (hit.exit.length > 16384) return false;
                try {
                  final token = jsonDecode(hit.exit);
                  if (token is! Map ||
                      token['version'] != 1 ||
                      token['epoch'] != epoch ||
                      token['proxy'] != hit.proxy ||
                      (hit.proxy.isEmpty && token['mode'] != mode) ||
                      token['selected'] is! Map) {
                    return false;
                  }
                  final selected = token['selected'] as Map;
                  return selected.entries.every(
                    (entry) =>
                        selections.containsKey(entry.key) &&
                        selections[entry.key] == entry.value,
                  );
                } on FormatException {
                  return false;
                }
              }),
      ],
    );
    return RouteCheck(
      coreEpoch: epoch,
      routeVersion: policy.snapshot.routeVersion,
      held: held,
    );
  }

  static Future<String?> _evidence(
    _Policy policy,
    List<String> chain,
    String proxy,
  ) {
    final nodes = policy.outbounds;
    final epoch = policy.snapshot.coreEpoch;
    final mode = policy.mode.name;
    return Isolate.run(() {
      if (chain.isEmpty || chain.length > 128) return null;
      final byName = {for (final node in nodes) node.name: node};
      if (chain.any((name) => !byName.containsKey(name))) return null;
      final selected = {
        for (final name in chain)
          if (byName[name]!.members.isNotEmpty) name: byName[name]!.selected,
      };
      if (selected.values.any(
        (value) => value == null || !chain.contains(value),
      )) {
        return null;
      }
      final token = jsonEncode({
        'version': 1,
        'epoch': epoch,
        'proxy': proxy,
        if (proxy.isEmpty) 'mode': mode,
        'selected': selected,
      });
      return token.length <= 16384 ? token : null;
    });
  }

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
    _configurationRevision++;
    _watching = false;
    _syncTimer();
    await _states.cancel();
    await _tail;
    await Future.wait([
      for (final operation in _configurationOperations.toList())
        operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]);
  }
}

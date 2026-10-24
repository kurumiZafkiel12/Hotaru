import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'mihomo_api.dart';

enum CoreStatus { stopped, validating, starting, running, failed }

/// Desktop-only adapter. Owns only its child process; never changes system
/// proxy settings itself (that is the platform adapter's job).
class MihomoController {
  CoreStatus status = CoreStatus.stopped;
  String? error;
  Process? _process;
  bool _busy = false;
  bool _disposed = false;

  MihomoApi? _api;

  /// Control API for the running core; null unless [status] is running.
  MihomoApi? get api => status == CoreStatus.running ? _api : null;

  /// The mixed HTTP/SOCKS port of a runtime (proxy) launch; null for
  /// diagnostic launches and when stopped.
  int? mixedPort;

  /// Mihomo version reported by the running core's health check.
  String? coreVersion;

  /// Picks a currently free loopback port instead of a fixed port.
  ///
  /// There is an inherent race between releasing the probe socket and the
  /// core binding the port; callers must still handle a bind failure (it
  /// surfaces as a normal startup failure).
  static Future<int> findFreePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      return socket.port;
    } finally {
      await socket.close();
    }
  }

  static String newSecret() {
    final random = Random.secure();
    return base64Url.encode(List.generate(32, (_) => random.nextInt(256)));
  }

  static Map<String, Object> diagnosticConfig(int port, String secret) {
    if (port < 1024 || port > 65535 || secret.length < 32) {
      throw ArgumentError('Invalid controller settings');
    }
    return {
      'mixed-port': 0,
      'allow-lan': false,
      'bind-address': '127.0.0.1',
      'port': 0,
      'socks-port': 0,
      'redir-port': 0,
      'tproxy-port': 0,
      'listeners': <Object>[],
      'external-controller-tls': '',
      'external-controller-unix': '',
      'external-controller-pipe': '',
      'external-ui': '',
      'external-controller': '127.0.0.1:$port',
      'secret': secret,
      'mode': 'direct',
      'log-level': 'silent',
      'ipv6': false,
      'tun': {'enable': false},
      'dns': {'enable': false},
      'rules': ['MATCH,DIRECT'],
    };
  }

  /// Diagnostic launch: validates and starts the core with all proxy
  /// entry points disabled. Proves the binary works; moves no traffic.
  Future<void> startDiagnostic(
    String executable,
    Directory directory,
    int port,
  ) async {
    final secret = newSecret();
    await _start(
      executable: executable,
      directory: directory,
      fileName: 'diagnostic.json',
      config: diagnosticConfig(port, secret),
      controllerPort: port,
      secret: secret,
      runtimeMixedPort: null,
      failureMessage: '内核启动失败：请检查路径、版本及控制端口是否被占用。',
    );
  }

  /// Runtime (proxy) launch: starts the core with a real mixed port from a
  /// config built by ProxyConfigBuilder. After this returns, traffic sent
  /// to 127.0.0.1:[mixedPort] is proxied by the core. Applying a selection
  /// afterwards is the caller's job via [api].
  Future<void> startRuntime(
    String executable,
    Directory directory, {
    required Map<String, dynamic> runtimeConfig,
    required int mixedPort,
  }) async {
    if (mixedPort < 1024 || mixedPort > 65535) {
      throw ArgumentError('Invalid mixed port');
    }
    final secret = newSecret();
    final controllerPort = await findFreePort();
    final config = <String, dynamic>{
      ...runtimeConfig,
      'mixed-port': mixedPort,
      'allow-lan': false,
      'bind-address': '127.0.0.1',
      'port': 0,
      'socks-port': 0,
      'redir-port': 0,
      'tproxy-port': 0,
      'listeners': <Object>[],
      'external-controller-tls': '',
      'external-controller-unix': '',
      'external-controller-pipe': '',
      'external-ui': '',
      'external-controller': '127.0.0.1:$controllerPort',
      'secret': secret,
      // TUN stays off in this stage regardless of the source config; it is
      // a separate privileged feature, not a config accident.
      'tun': {'enable': false},
    };
    await _start(
      executable: executable,
      directory: directory,
      fileName: 'runtime.json',
      config: config,
      controllerPort: controllerPort,
      secret: secret,
      runtimeMixedPort: mixedPort,
      failureMessage: '代理启动失败：请检查内核路径、配置内容与本地端口是否被占用。',
    );
  }

  Future<void> _start({
    required String executable,
    required Directory directory,
    required String fileName,
    required Map<String, dynamic> config,
    required int controllerPort,
    required String secret,
    required int? runtimeMixedPort,
    required String failureMessage,
  }) async {
    if (_disposed) throw StateError('Controller has been disposed');
    if (_busy || _process != null) throw StateError('Core is already active');
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      throw UnsupportedError('Desktop adapter only');
    }
    _busy = true;
    error = null;
    File? configFile;
    try {
      status = CoreStatus.validating;
      if (!File(executable).isAbsolute || !await File(executable).exists()) {
        throw ArgumentError(
          'Select an existing absolute Mihomo executable path',
        );
      }
      await directory.create(recursive: true);
      configFile = File('${directory.path}${Platform.pathSeparator}$fileName');
      await configFile.writeAsString(jsonEncode(config), flush: true);
      final validation = await Process.start(executable, [
        '-t',
        '-d',
        directory.path,
        '-f',
        configFile.path,
      ]);
      // Never include configuration or credential-bearing core output in UI logs.
      unawaited(validation.stdout.drain<void>());
      unawaited(validation.stderr.drain<void>());
      final code = await validation.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          validation.kill();
          throw TimeoutException('Configuration validation timed out');
        },
      );
      if (code != 0) {
        throw StateError('Mihomo rejected the configuration');
      }
      if (_disposed) throw StateError('Controller disposed during validation');
      status = CoreStatus.starting;
      final child = await Process.start(executable, [
        '-d',
        directory.path,
        '-f',
        configFile.path,
      ]);
      _process = child;
      if (_disposed) {
        await _terminate();
        throw StateError('Controller disposed during startup');
      }
      unawaited(child.stdout.drain<void>());
      unawaited(child.stderr.drain<void>());
      unawaited(
        child.exitCode.then((_) {
          if (identical(_process, child)) {
            _process = null;
            status = CoreStatus.failed;
            error = 'Core exited unexpectedly';
          }
        }),
      );
      final candidate = MihomoApi(port: controllerPort, secret: secret);
      // Registered immediately so failure paths close it via _terminate;
      // the public [api] getter still hides it until status is running.
      _api = candidate;
      String? version;
      for (var attempt = 0; attempt < 40 && version == null; attempt++) {
        if (_process == null) throw StateError('Core exited during startup');
        try {
          version = await candidate.version();
        } catch (_) {
          /* retry bounded local health check */
        }
        if (version == null) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
      if (version == null || !identical(_process, child)) {
        throw TimeoutException('Core health check failed');
      }
      coreVersion = version;
      mixedPort = runtimeMixedPort;
      status = CoreStatus.running;
    } catch (_) {
      await _terminate();
      status = CoreStatus.failed;
      error = failureMessage;
      rethrow;
    } finally {
      // Config carries node credentials and an ephemeral API secret; remove
      // once startup finishes (the core has already read it by then).
      try {
        if (configFile != null && await configFile.exists()) {
          await configFile.delete();
        }
      } finally {
        _busy = false;
      }
    }
  }

  Future<void> _terminate() async {
    _api?.close();
    _api = null;
    mixedPort = null;
    coreVersion = null;
    final child = _process;
    _process = null;
    if (child == null) return;
    try {
      child.kill();
      await child.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          child.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {
      // The process may already have exited; termination is best-effort and
      // must never leave callers (in particular dispose) hanging or throwing.
    }
  }

  Future<void> stop() async {
    if (_busy) throw StateError('Wait for startup to finish');
    await _terminate();
    status = CoreStatus.stopped;
  }

  /// Stops any owned core process and releases API resources.
  ///
  /// Unlike [stop], dispose is safe to call while a start is still in
  /// progress, safe to call more than once, and never throws: a page or the
  /// app being torn down must not leak the child process just because the
  /// controller was busy. After dispose the controller cannot be reused.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _terminate();
    status = CoreStatus.stopped;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

enum CoreStatus { stopped, validating, starting, running, failed }

/// Desktop-only adapter. Owns only its child process; never changes system proxy.
class MihomoController {
  CoreStatus status = CoreStatus.stopped;
  String? error;
  Process? _process;
  bool _busy = false;
  final HttpClient _http = HttpClient();

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

  Future<void> startDiagnostic(
    String executable,
    Directory directory,
    int port,
  ) async {
    if (_busy || _process != null) throw StateError('Core is already active');
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      throw UnsupportedError('Desktop adapter only');
    }
    _busy = true;
    error = null;
    File? config;
    try {
      status = CoreStatus.validating;
      if (!File(executable).isAbsolute || !await File(executable).exists()) {
        throw ArgumentError(
          'Select an existing absolute Mihomo executable path',
        );
      }
      await directory.create(recursive: true);
      final secret = newSecret();
      config = File(
        '${directory.path}${Platform.pathSeparator}diagnostic.json',
      );
      await config.writeAsString(
        jsonEncode(diagnosticConfig(port, secret)),
        flush: true,
      );
      final validation = await Process.start(executable, [
        '-t',
        '-d',
        directory.path,
        '-f',
        config.path,
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
        throw StateError('Mihomo rejected diagnostic configuration');
      }
      status = CoreStatus.starting;
      final child = await Process.start(executable, [
        '-d',
        directory.path,
        '-f',
        config.path,
      ]);
      _process = child;
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
      for (var attempt = 0; attempt < 30; attempt++) {
        if (_process == null) throw StateError('Core exited during startup');
        try {
          final request = await _http
              .getUrl(Uri.parse('http://127.0.0.1:$port/version'))
              .timeout(const Duration(seconds: 1));
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer $secret',
          );
          final response = await request.close().timeout(
            const Duration(seconds: 1),
          );
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 1));
          if (response.statusCode == 200 &&
              jsonDecode(body)['version'] is String &&
              identical(_process, child)) {
            status = CoreStatus.running;
            return;
          }
        } catch (_) {
          /* retry bounded local health check */
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw TimeoutException('Core health check failed');
    } catch (_) {
      await _terminate();
      status = CoreStatus.failed;
      error = '内核启动失败：请检查路径、版本及控制端口是否被占用。';
      rethrow;
    } finally {
      // Config carries an ephemeral API secret; remove once startup finishes.
      try {
        if (config != null && await config.exists()) await config.delete();
      } finally {
        _busy = false;
      }
    }
  }

  Future<void> _terminate() async {
    final child = _process;
    _process = null;
    if (child != null) {
      child.kill();
      await child.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          child.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
  }

  Future<void> stop() async {
    if (_busy) throw StateError('Wait for startup to finish');
    await _terminate();
    status = CoreStatus.stopped;
  }

  Future<void> dispose() async {
    await stop();
    _http.close(force: true);
  }
}

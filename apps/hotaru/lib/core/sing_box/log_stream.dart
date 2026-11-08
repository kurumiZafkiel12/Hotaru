import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../adapter.dart';
import '../logs.dart';

final class SingBoxLogStream {
  static final _sensitive = RegExp(
    r'''["\']?(?:password|authorization|credential|private[_-]?key|token)["\']?\s*[:=]''',
    caseSensitive: false,
  );
  static final _credentials = RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*://)[^\s/@]+@');

  final Uri endpoint;
  final String secret;
  final void Function() onClose;
  final HttpClient _client = HttpClient();
  final BytesBuilder _line = BytesBuilder(copy: false);
  late final StreamController<CoreLogMessage> _controller;
  StreamSubscription<List<int>>? _subscription;
  Future<void>? _closing;
  bool _closed = false;
  bool _paused = false;

  SingBoxLogStream({
    required this.endpoint,
    required this.secret,
    required this.onClose,
  }) {
    _client.findProxy = (_) => 'DIRECT';
    _client.connectionTimeout = const Duration(seconds: 10);
    _controller = StreamController<CoreLogMessage>(
      sync: true,
      onListen: () => unawaited(_open()),
      onCancel: close,
      onPause: () {
        _paused = true;
        _subscription?.pause();
      },
      onResume: () {
        _paused = false;
        _subscription?.resume();
      },
    );
  }

  Stream<CoreLogMessage> get stream => _controller.stream;

  Future<void> _open() async {
    if (_closed) return;
    try {
      final request = await _client.getUrl(
        endpoint.replace(path: '/logs', queryParameters: {'level': 'trace'}),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      if (_closed) {
        request.abort();
        return;
      }
      final response = await request.close();
      if (_closed) return;
      if (response.statusCode != HttpStatus.ok) {
        _fail(CoreAdapterException('log_http', status: response.statusCode));
        return;
      }
      _subscription = response.listen(
        _add,
        onError: (Object _) =>
            _fail(const CoreAdapterException('log_transport')),
        onDone: () {
          if (_line.length != 0 && !_closed) {
            _fail(const CoreAdapterException('invalid_log_response'));
          } else {
            unawaited(close());
          }
        },
      );
      if (_paused) _subscription!.pause();
    } catch (_) {
      if (!_closed) _fail(const CoreAdapterException('log_transport'));
    }
  }

  void _add(List<int> chunk) {
    var start = 0;
    while (!_closed && start < chunk.length) {
      final newline = chunk.indexOf(10, start);
      final end = newline < 0 ? chunk.length : newline;
      if (_line.length + end - start > 64 * 1024) {
        _fail(const CoreAdapterException('log_entry_too_large'));
        return;
      }
      _line.add(chunk.sublist(start, end));
      if (newline < 0) return;
      try {
        final text = utf8.decode(_line.takeBytes()).trim();
        if (text.isNotEmpty) {
          final value = jsonDecode(text);
          if (value is! Map<String, dynamic> ||
              value['payload'] is! String ||
              !const {
                'trace',
                'debug',
                'info',
                'warn',
                'warning',
                'error',
                'fatal',
                'panic',
              }.contains(value['type'])) {
            throw const FormatException();
          }
          _controller.add(
            CoreLogMessage(
              level: value['type'] as String,
              payload: _redact(value['payload'] as String),
            ),
          );
        }
      } on FormatException {
        _fail(const CoreAdapterException('invalid_log_response'));
        return;
      }
      start = end + 1;
    }
  }

  String _redact(String payload) {
    if (_sensitive.hasMatch(payload)) {
      return '[Authentication details redacted]';
    }
    return payload
        .replaceAll(secret, '[redacted]')
        .replaceAllMapped(_credentials, (match) => '${match[1]}[redacted]@');
  }

  void _fail(CoreAdapterException error) {
    if (_closed) return;
    _controller.addError(error);
    unawaited(close());
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _client.close(force: true);
    _line.clear();
    onClose();
    await _subscription?.cancel();
    unawaited(_controller.close());
  }
}

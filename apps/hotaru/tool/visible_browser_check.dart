import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:hotaru/features/browser_diagnostics/tool_browser.dart';
import 'package:hotaru/features/browser_diagnostics/tool_site.dart';
import 'package:hotaru/features/browser_diagnostics/tool_translation.dart';
import 'package:material_ui/material_ui.dart';

final visibleBrowserKey = GlobalKey<VisibleBrowserCheckState>();

class VisibleBrowserCheck extends StatefulWidget {
  const VisibleBrowserCheck({super.key});

  @override
  State<VisibleBrowserCheck> createState() => VisibleBrowserCheckState();
}

class VisibleBrowserCheckState extends State<VisibleBrowserCheck> {
  WindowsToolBrowser? _browser;
  HttpServer? _proxy;
  final _sockets = <Socket>{};
  int _receipts = 0;
  bool _ready = false;

  Future<void> _relay(HttpRequest request) async {
    if (request.method != 'CONNECT' ||
        request.uri.toString() != 'browserleaks.com:443') {
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }
    Socket? upstream;
    Socket? client;
    try {
      upstream = await Socket.connect(
        'browserleaks.com',
        443,
        timeout: const Duration(seconds: 15),
      );
      _sockets.add(upstream);
      client = await request.response.detachSocket(writeHeaders: false);
      _sockets.add(client);
      _receipts++;
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await client.flush();
      await Future.wait([
        upstream.cast<List<int>>().pipe(client),
        client.cast<List<int>>().pipe(upstream),
      ]);
    } catch (_) {
      upstream?.destroy();
      client?.destroy();
    } finally {
      _sockets.remove(upstream);
      _sockets.remove(client);
    }
  }

  Future<Map<String, Object?>> check(ToolSite site) async {
    _receipts = 0;
    final observed = Completer<Map<String, Object?>>();
    final proxy = _proxy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    proxy.listen(
      (request) => unawaited(_relay(request).catchError((Object _) {})),
    );
    final script =
        toolTranslationScript({
          'DNS Leak Test': 'DNS 泄漏测试',
          'WebRTC Leak Test': 'WebRTC 泄漏测试',
        }, 'zh-CN') +
        r'''
(() => ({
  localized: document.body.innerText.includes('DNS 泄漏测试') || document.body.innerText.includes('WebRTC 泄漏测试'),
  language: document.documentElement.lang,
  visible: document.visibilityState === 'visible',
  width: innerWidth,
  height: innerHeight
}))();
''';
    final browser = _browser = WindowsToolBrowser(
      site: site,
      port: proxy.port,
      locale: 'zh-CN',
      temporaryPath: Directory.systemTemp.path,
      translationScript: script,
      onProgress: (_) {},
      onLocation: (_) {},
      onFailure: () {
        if (!observed.isCompleted) {
          observed.completeError(StateError('Visible tool page failed'));
        }
      },
      onDocumentReady: (value) {
        if (value is String) value = jsonDecode(value);
        if (!observed.isCompleted && value is Map) {
          observed.complete(Map<String, Object?>.from(value));
        }
      },
    );
    await browser.initialize().timeout(const Duration(seconds: 25));
    if (!mounted) throw StateError('Harness disposed');
    setState(() => _ready = true);
    final result = await observed.future.timeout(const Duration(seconds: 50));
    await SchedulerBinding.instance.endOfFrame;
    return {
      'visible_webview':
          result['visible'] == true &&
          result['width'] is num &&
          (result['width'] as num) > 300 &&
          result['height'] is num &&
          (result['height'] as num) > 300,
      'forced_proxy_receipt': _receipts > 0,
      'translated_fields':
          result['localized'] == true && result['language'] == 'zh-CN',
      'proxy_receipt_count': _receipts,
      'kind': site.name,
    };
  }

  Future<void> finish() async {
    final browser = _browser;
    final proxy = _proxy;
    _browser = null;
    _proxy = null;
    if (mounted) {
      setState(() => _ready = false);
      await SchedulerBinding.instance.endOfFrame;
    }
    try {
      await browser?.close();
    } finally {
      for (final socket in _sockets.toList()) {
        socket.destroy();
      }
      _sockets.clear();
      await proxy?.close(force: true);
    }
  }

  @override
  void dispose() {
    unawaited(_browser?.close() ?? Future.value());
    unawaited(_proxy?.close(force: true) ?? Future.value());
    for (final socket in _sockets) {
      socket.destroy();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: _ready
        ? _browser!.build(context)
        : const Center(child: Text('Hotaru browser diagnostic validation')),
  );
}

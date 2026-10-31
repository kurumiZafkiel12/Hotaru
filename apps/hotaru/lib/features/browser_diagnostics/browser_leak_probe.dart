import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:hotaru/common/browser_leak_result.dart';

class BrowserLeakProbe {
  bool _cancelled = false;
  final _cancelledSignal = Completer<void>();

  void cancel() {
    _cancelled = true;
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
  }

  void _check() {
    if (_cancelled) throw const FormatException('diagnostic cancelled');
  }

  Future<BrowserLeakResult> run(
    BrowserLeakKind kind,
    String temporaryPath,
  ) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('WebView2 requires Windows');
    }
    Directory? directory;
    PlatformWebViewEnvironment? environment;
    PlatformHeadlessInAppWebView? webview;
    try {
      _check();
      if (await PlatformWebViewEnvironment.static()
              .getAvailableVersion()
              .timeout(const Duration(seconds: 10)) ==
          null) {
        throw UnsupportedError('WebView2 runtime unavailable');
      }
      _check();
      directory = await Directory(temporaryPath).createTemp('browser-leak-');
      environment = await PlatformWebViewEnvironment.static()
          .create(
            settings: WebViewEnvironmentSettings(
              userDataFolder: directory.path,
            ),
          )
          .timeout(const Duration(seconds: 15));
      _check();
      final loaded = Completer<PlatformInAppWebViewController>();
      final path = kind.name;
      webview = PlatformHeadlessInAppWebView(
        PlatformHeadlessInAppWebViewCreationParams(
          controllerFromPlatform: (controller) => controller,
          webViewEnvironment: environment,
          initialUrlRequest: URLRequest(
            url: WebUri('https://browserleaks.com/$path'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            mediaPlaybackRequiresUserGesture: true,
            javaScriptCanOpenWindowsAutomatically: false,
          ),
          onPermissionRequest: (_, request) async => PermissionResponse(
            resources: request.resources,
            action: PermissionResponseAction.DENY,
          ),
          onGeolocationPermissionsShowPrompt: (_, origin) async =>
              GeolocationPermissionShowPromptResponse(
                origin: origin,
                allow: false,
                retain: false,
              ),
          onCreateWindow: (_, _) async => false,
          shouldOverrideUrlLoading: (_, action) async {
            final uri = action.request.url;
            return uri?.scheme == 'https' && uri?.host == 'browserleaks.com'
                ? NavigationActionPolicy.ALLOW
                : NavigationActionPolicy.CANCEL;
          },
          onLoadStop: (controller, url) {
            if (!loaded.isCompleted &&
                url?.host == 'browserleaks.com' &&
                url?.path == '/$path') {
              loaded.complete(controller);
            }
          },
        ),
      );
      await webview.run().timeout(const Duration(seconds: 15));
      _check();
      final controller = await Future.any([
        loaded.future,
        _cancelledSignal.future.then<PlatformInAppWebViewController>(
          (_) => throw const FormatException('diagnostic cancelled'),
        ),
      ]).timeout(const Duration(seconds: 25));
      _check();
      if (kind == BrowserLeakKind.dns) {
        final clicked = await controller.evaluateJavascript(
          source: '''
(() => { const button = document.querySelector('#dns-test');
if (!button) return false; button.click(); return true; })()
''',
        );
        if (clicked != true) {
          throw const FormatException('DNS test control missing');
        }
      }
      final deadline = DateTime.now().add(const Duration(seconds: 65));
      BrowserLeakResult? result;
      do {
        _check();
        final value = await controller
            .evaluateJavascript(source: _snapshot)
            .timeout(const Duration(seconds: 5));
        result = BrowserLeakResult.fromSnapshot(kind, value);
        if (result.completed) return result;
        await Future.any([
          Future<void>.delayed(const Duration(milliseconds: 700)),
          _cancelledSignal.future,
        ]);
      } while (DateTime.now().isBefore(deadline));
      return result;
    } finally {
      try {
        await webview?.dispose();
      } finally {
        await environment?.dispose();
        if (directory != null && await directory.exists()) {
          try {
            await directory.delete(recursive: true);
          } on FileSystemException {
            // WebView2 can retain cache handles until its process exits.
          }
        }
      }
    }
  }
}

const _snapshot = r'''
(() => {
  const text = id => document.getElementById(id)?.innerText?.trim() || '';
  const fields = Object.fromEntries(['client-ipv4', 'client-ipv6',
    'rtc-peerconnection', 'rtc-public', 'rtc-local', 'rtc-leak']
    .map(id => [id, text(id)]));
  const resolvers = Array.from(document.querySelectorAll('#dns-list tr'))
    .map(row => { const cells = row.querySelectorAll('td'); return {
      ip: cells[0]?.innerText?.trim() || '',
      organization: cells[1]?.innerText?.trim() || '',
      country: cells[2]?.innerText?.trim() || ''}; })
    .filter(row => row.ip);
  const button = document.querySelector('#dns-test');
  const completed = location.pathname === '/dns'
    ? resolvers.length > 0 && /^Found\s+\d+\s+Servers?/i.test(button?.innerText || '')
    : /\b(?:No Leak|Leak Detected|Your IP|Potential Leak)\b/i.test(fields['rtc-leak']);
  return {origin: location.origin, fields, resolvers, completed};
})()
''';

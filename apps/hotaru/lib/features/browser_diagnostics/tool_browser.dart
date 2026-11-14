import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';

import 'tool_site.dart';
import 'webview_environment.dart';

abstract interface class ToolBrowser {
  Future<void> initialize();
  Widget build(BuildContext context);
  Future<void> close();
}

final class WindowsToolBrowser implements ToolBrowser {
  final ToolSite site;
  final int port;
  final String locale;
  final String temporaryPath;
  final String translationScript;
  final void Function(int) onProgress;
  final void Function(Uri) onLocation;
  final void Function() onFailure;
  final void Function(Object?)? onDocumentReady;
  PlatformWebViewEnvironment? _environment;
  PlatformInAppWebViewWidget? _view;
  Directory? _directory;
  bool _closed = false;
  Future<void> _cleanup = Future.value();
  Future<void>? _initialization;

  WindowsToolBrowser({
    required this.site,
    required this.port,
    required this.locale,
    required this.temporaryPath,
    required this.translationScript,
    required this.onProgress,
    required this.onLocation,
    required this.onFailure,
    this.onDocumentReady,
  });

  void _check() {
    if (_closed) throw StateError('Browser session is closed');
  }

  @override
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      _check();
      if (!Platform.isWindows) {
        throw UnsupportedError('WebView2 requires Windows');
      }
      final arguments = toolBrowserArguments(port, locale);
      if (await PlatformWebViewEnvironment.static().getAvailableVersion() ==
          null) {
        throw UnsupportedError('WebView2 runtime unavailable');
      }
      _check();
      final directory = await Directory(
        temporaryPath,
      ).createTemp('hotaru-tool-');
      _directory = directory;
      _check();
      _environment = await createLeakWebViewEnvironment(
        directory.path,
        browserArguments: arguments,
      );
      _directory ??= directory;
      _check();
      _view = PlatformInAppWebViewWidget(
        PlatformInAppWebViewWidgetCreationParams(
          controllerFromPlatform: (controller) => controller,
          webViewEnvironment: _environment,
          initialUrlRequest: URLRequest(url: WebUri(site.address)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            javaScriptCanOpenWindowsAutomatically: false,
            mediaPlaybackRequiresUserGesture: true,
            useOnDownloadStart: true,
          ),
          onProgressChanged: (_, progress) {
            if (!_closed) onProgress(progress);
          },
          onLoadStop: (controller, uri) async {
            if (_closed || !ToolSite.allowsNavigation(uri)) return;
            onLocation(uri!);
            try {
              final observation = await controller.evaluateJavascript(
                source: translationScript,
              );
              if (!_closed) onDocumentReady?.call(observation);
              if (!_closed) onProgress(100);
            } catch (_) {
              if (!_closed) onFailure();
            }
          },
          onReceivedError: (_, request, _) {
            if (!_closed && request.isForMainFrame == true) onFailure();
          },
          shouldOverrideUrlLoading: (_, action) async =>
              ToolSite.allowsNavigation(action.request.url)
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL,
          onCreateWindow: (controller, action) async {
            final uri = action.request.url;
            if (!_closed && ToolSite.allowsNavigation(uri)) {
              await controller.loadUrl(urlRequest: URLRequest(url: uri));
            }
            return false;
          },
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
          onDownloadStartRequest: (_, _) async {},
        ),
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    _check();
    return _view!.build(context);
  }

  @override
  Future<void> close() {
    _closed = true;
    final view = _view;
    final environment = _environment;
    final directory = _directory;
    _view = null;
    _environment = null;
    _directory = null;
    _cleanup = _cleanup.catchError((Object _) {}).then((_) async {
      try {
        view?.dispose();
      } finally {
        try {
          await environment?.dispose();
        } finally {
          if (directory != null) {
            try {
              await directory.delete(recursive: true);
            } on FileSystemException {
              // WebView2 may retain profile handles briefly after disposal.
            }
          }
        }
      }
    });
    return _cleanup;
  }
}

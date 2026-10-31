import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';

Future<WindowsWebViewEnvironment> createLeakWebViewEnvironment(
  String path,
) async {
  final environment = await WindowsWebViewEnvironment.static().create(
    settings: WebViewEnvironmentSettings(userDataFolder: path),
  );
  final channel =
      'com.pichillilorenzo/flutter_webview_environment_${environment.id}';
  // Windows 0.6.0 binds the factory's ID instead of the created environment's ID.
  if (environment.channel?.name != channel) {
    environment.channel?.setMethodCallHandler(null);
    environment.channel = MethodChannel(channel);
    environment.initMethodCallHandler();
  }
  return environment;
}

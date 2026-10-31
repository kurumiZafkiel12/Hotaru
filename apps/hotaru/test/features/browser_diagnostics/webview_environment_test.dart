import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:hotaru/features/browser_diagnostics/webview_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'created WebView2 environment disposes through its own native channel',
    () async {
      const factory = MethodChannel(
        'com.pichillilorenzo/flutter_webview_environment',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MethodChannel? created;
      String? createdId;
      String? disposedMethod;
      messenger.setMockMethodCallHandler(factory, (call) async {
        expect(call.method, 'create');
        final args = call.arguments as Map;
        createdId = args['id'] as String;
        expect(
          (args['settings'] as Map)['userDataFolder'],
          '/temporary/isolated',
        );
        created = MethodChannel('${factory.name}_$createdId');
        messenger.setMockMethodCallHandler(created!, (call) async {
          disposedMethod = call.method;
          return null;
        });
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(factory, null);
        if (created != null) messenger.setMockMethodCallHandler(created!, null);
      });
      final environment = await createLeakWebViewEnvironment(
        '/temporary/isolated',
      );
      expect(environment.id, createdId);
      expect(environment.channel?.name, created!.name);
      await environment.dispose();
      expect(disposedMethod, 'dispose');
    },
  );
}

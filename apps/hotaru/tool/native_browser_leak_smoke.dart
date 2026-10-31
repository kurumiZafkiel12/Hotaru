import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hotaru/common/browser_leak_result.dart';
import 'package:hotaru/common/constant.dart';
import 'package:hotaru/features/browser_diagnostics/browser_leak_probe.dart';
import 'package:material_ui/material_ui.dart';

Future<void> checkBrowserLeak() async {
  final report = <String, Object?>{
    'source_sha': const String.fromEnvironment('NATIVE_SMOKE_SOURCE'),
    'safe_mode': safeModeBuild,
    'scope':
        'Actual Windows WebView2 and BrowserLeaks on an isolated CI host; no proxy/TUN or external-browser safety claim',
  };
  final results = <Map<String, Object?>>[];
  if (safeModeBuild) {
    for (final kind in BrowserLeakKind.values) {
      try {
        final result = await BrowserLeakProbe().run(
          kind,
          Directory.systemTemp.path,
        );
        results.add({
          'kind': kind.name,
          'completed': result.completed,
          'resolver_count': result.resolvers.length,
          'rtc_supported': result.supported,
          'remote_count': result.remote.length,
          'public_count': result.public.length,
          'rtc_matching': result.rtcMatches,
          'rtc_mismatch': result.hasRtcMismatch,
        });
      } catch (error) {
        results.add({'kind': kind.name, 'error': error.toString()});
      }
    }
  }
  report['results'] = results;
  final encoded = jsonEncode(report);
  debugPrint('HOTARU_NATIVE_BROWSER $encoded');
  final destination = Platform.environment['HOTARU_NATIVE_BROWSER_REPORT'];
  if (destination != null) await File(destination).writeAsString('$encoded\n');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Hotaru browser diagnostic validation')),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(checkBrowserLeak()),
  );
}

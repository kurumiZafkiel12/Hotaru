import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hotaru/common/constant.dart';
import 'package:hotaru/features/browser_diagnostics/tool_site.dart';
import 'package:material_ui/material_ui.dart';

import 'visible_browser_check.dart';

Future<void> checkBrowserTools() async {
  final report = <String, Object?>{
    'source_sha': const String.fromEnvironment('NATIVE_SMOKE_SOURCE'),
    'safe_mode': safeModeBuild,
    'scope':
        'Visible localized Windows WebView2 through an owned loopback proxy; validates the tool wrapper, not a TUN or a leak verdict',
  };
  final results = <Map<String, Object?>>[];
  if (safeModeBuild) {
    for (final site in [ToolSite.dns, ToolSite.webrtc]) {
      try {
        final result = await visibleBrowserKey.currentState!.check(site);
        await visibleBrowserKey.currentState!.finish();
        results.add({...result, 'visible_cleanup': true});
      } catch (error) {
        await visibleBrowserKey.currentState!.finish();
        results.add({'kind': site.name, 'error': error.runtimeType.toString()});
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
  runApp(MaterialApp(home: VisibleBrowserCheck(key: visibleBrowserKey)));
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(checkBrowserTools()),
  );
}

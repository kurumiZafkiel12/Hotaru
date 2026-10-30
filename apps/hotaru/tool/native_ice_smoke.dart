import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hotaru/common/constant.dart';
import 'package:hotaru/common/ice_probe.dart';
import 'package:material_ui/material_ui.dart';

Future<void> checkNativeIce() async {
  final result = <String, Object?>{
    'source_sha': const String.fromEnvironment('NATIVE_SMOKE_SOURCE'),
    'safe_mode': safeModeBuild,
    'scope':
        'Native data-channel ICE on a disposable test host; no proxy, TUN, camera, microphone or leakage-success claim',
  };
  if (!safeModeBuild) {
    result['plugin_started'] = false;
    result['error'] = 'safe-mode-required';
  } else {
    try {
      final probe = await IceProbe().run();
      result.addAll({
        'plugin_started':
            probe.error != 'unavailable' && probe.candidates.isNotEmpty,
        'gather_complete': probe.completed,
        'candidate_count': probe.candidates.length,
        'public_candidate_count': probe.candidates
            .where((candidate) => candidate.isPublic)
            .length,
        'candidate_types':
            probe.candidates.map((candidate) => candidate.kind).toSet().toList()
              ..sort(),
        'verdict_without_expected_exit': probe.verdict(const []).name,
        'error': probe.error,
      });
    } catch (error) {
      result['plugin_started'] = false;
      result['error'] = error.runtimeType.toString();
    }
  }
  final json = jsonEncode(result);
  debugPrint('HOTARU_NATIVE_ICE $json');
  final destination = Platform.environment['HOTARU_NATIVE_ICE_REPORT'];
  if (destination != null && destination.isNotEmpty) {
    await File(destination).writeAsString('$json\n');
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Hotaru native ICE validation · test harness'),
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(checkNativeIce()),
  );
}

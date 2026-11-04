import 'dart:convert';
import 'dart:io';

import '../lib/core/adapter.dart';
import '../lib/core/sing_box/clash_api_adapter.dart';

Future<void> main() async {
  final adapter = SingBoxClashApiAdapter(
    endpoint: Uri.parse(Platform.environment['HOTARU_PROBE_API']!),
    secret: Platform.environment['HOTARU_PROBE_SECRET']!,
  );
  try {
    final nodes = await adapter.outbounds();
    if (!nodes.any((node) => node.name == 'node-a')) {
      throw StateError('Missing controlled outbound');
    }
    final snapshot = await adapter.connections();
    final active = snapshot.entries.where(
      (entry) => entry.chain.contains('node-b'),
    );
    if (active.length != 1 || active.single.download == 0) {
      throw StateError('Active route or transfer counter mismatch');
    }
    await adapter.selectOutbound('selected', 'node-a');
    final delay = await adapter.delay(
      'node-b',
      Uri.parse(Platform.environment['HOTARU_PROBE_TARGET']!),
      const Duration(seconds: 3),
    );
    final selection = (await adapter.outbounds()).singleWhere(
      (node) => node.name == 'selected',
    );
    if (selection.selected != 'node-a') {
      throw StateError('Node-specific delay changed the selected route');
    }
    await adapter.closeConnection(active.single.id);
    if ((await adapter.connections()).entries.any(
      (entry) => entry.id == active.single.id,
    )) {
      throw StateError('Connection was not closed');
    }
    stdout.writeln(
      jsonEncode({'adapter': 'passed', 'delayMs': delay.inMilliseconds}),
    );
  } on CoreAdapterException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    adapter.close();
  }
}
// The Windows protocol job runs directly with the standalone Dart SDK.
// ignore_for_file: avoid_relative_lib_imports

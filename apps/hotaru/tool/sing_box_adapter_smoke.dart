import 'dart:convert';
import 'dart:io';

import '../lib/core/adapter.dart';
import '../lib/core/config/profile.dart';
import '../lib/core/sing_box/clash_api_adapter.dart';
import '../lib/core/sing_box/config_builder.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--build-config')) {
    final input =
        jsonDecode(await utf8.decoder.bind(stdin).join())
            as Map<String, dynamic>;
    final profile = CoreProfileSpec(
      nodes: [
        for (final node in input['nodes'] as List)
          CoreNodeSpec(
            tag: node['tag'] as String,
            protocol: CoreNodeProtocol.http,
            server: '127.0.0.1',
            port: node['port'] as int,
          ),
      ],
      selectors: [
        CoreSelectorSpec(tag: 'selected', members: ['node-a', 'node-b']),
      ],
      finalOutbound: 'selected',
    );
    final result = await SingBoxConfigBuilder().build(
      profile,
      CoreListenerSpec(
        mixedPort: input['mixedPort'] as int,
        controllerPort: input['controllerPort'] as int,
        secret: input['secret'] as String,
      ),
    );
    if (result.json == null) {
      throw StateError('Fixture configuration is invalid');
    }
    stdout.writeln(result.json);
    return;
  }
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

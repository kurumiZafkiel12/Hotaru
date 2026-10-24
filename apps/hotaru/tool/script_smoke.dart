import 'dart:io';

import 'package:hotaru/profiles/overrides.dart';
import 'package:hotaru/profiles/importer.dart';

Future<void> main(List<String> args) async {
  final node = args.single;
  final result = await ProfileOverrides.apply(
    {
      'rules': ['MATCH,DIRECT'],
    },
    {},
    'function main(config) { config.mode = "global"; return config; }',
    nodeExecutable: node,
  );
  if (result['mode'] != 'global') throw StateError('Script did not execute');
  final runtime = await ProfileOverrides.buildRuntime(
    source: {
      'proxies': [
        {'name': 'a', 'type': 'direct'},
      ],
    },
    mode: ImportMode.nodesOnly,
    selectedNode: 'a',
    overlay: {
      'rules': ['MATCH,REJECT'],
    },
    script: 'function main(config) { config.mode = "direct"; return config; }',
    nodeExecutable: node,
  );
  if (runtime['mode'] != 'direct' ||
      runtime['rules'].single != 'MATCH,REJECT' ||
      runtime['proxy-groups'] is! List) {
    throw StateError('Runtime generation overwrote user overlays');
  }
  for (final script in [
    'function main(c) { while(true){} }',
    'function main(c) { return require("node:fs").readFileSync("secret"); }',
    'function main(c) { return process.env; }',
    'function main(c) { return 1; }',
    'function main(c) { return this.constructor.constructor("return process")(); }',
  ]) {
    var rejected = false;
    try {
      await ProfileOverrides.apply({}, {}, script, nodeExecutable: node);
    } catch (_) {
      rejected = true;
    }
    if (!rejected) throw StateError('Invalid script was accepted');
  }
  stdout.writeln(
    'PASS Script transforms, timeout, result type, host globals and dynamic code rejection',
  );
}

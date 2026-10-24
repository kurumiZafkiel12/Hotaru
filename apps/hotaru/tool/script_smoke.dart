import 'dart:io';

import 'package:hotaru/profiles/overrides.dart';

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

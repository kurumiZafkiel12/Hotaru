import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../core/proxy_config.dart';
import 'importer.dart';

/// Source subscription -> recursive Merge (lists replace) -> user's Script.
/// Never executes script supplied by a remote subscription.
class ProfileOverrides {
  static Future<Map<String, dynamic>> buildRuntime({
    required Map<String, dynamic> source,
    required ImportMode mode,
    required String selectedNode,
    Map<String, dynamic> overlay = const {},
    String script = '',
    String? nodeExecutable,
  }) => apply(
    ProxyConfigBuilder.build(
      profileConfig: source,
      mode: mode,
      selectedNode: selectedNode,
    ),
    overlay,
    script,
    nodeExecutable: nodeExecutable,
  );

  static Map<String, dynamic> parseMerge(String text) {
    if (text.trim().isEmpty) return {};
    final result = jsonDecode(jsonEncode(loadYaml(text)));
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Merge 必须是 YAML/JSON 对象');
    }
    return result;
  }

  static Map<String, dynamic> merge(
    Map<String, dynamic> original,
    Map<String, dynamic> overlay,
  ) {
    final result = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
    for (final entry in overlay.entries) {
      final old = result[entry.key];
      result[entry.key] =
          old is Map<String, dynamic> && entry.value is Map<String, dynamic>
          ? merge(old, entry.value as Map<String, dynamic>)
          : jsonDecode(jsonEncode(entry.value));
    }
    return result;
  }

  static Future<Map<String, dynamic>> apply(
    Map<String, dynamic> source,
    Map<String, dynamic> overlay,
    String script, {
    String? nodeExecutable,
  }) async {
    final config = merge(source, overlay);
    if (script.trim().isEmpty) return config;
    if (utf8.encode(script).length > 256 * 1024) {
      throw const FormatException('Script 超过 256 KiB');
    }
    final executable =
        nodeExecutable ??
        '${File(Platform.resolvedExecutable).parent.path}/runtime/node.exe';
    final process = await Process.start(
      executable,
      ['--permission', '--max-old-space-size=64', '-e', _host],
      includeParentEnvironment: false,
      environment: {
        if (Platform.environment['SystemRoot'] != null)
          'SystemRoot': Platform.environment['SystemRoot']!,
      },
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    try {
      process.stdin.write(jsonEncode({'config': config, 'script': script}));
      await process.stdin.close();
      final code = await process.exitCode.timeout(const Duration(seconds: 5));
      final text = await output;
      await errors;
      if (code != 0 || utf8.encode(text).length > 4 * 1024 * 1024) {
        throw const FormatException('Script 执行失败或超时，旧配置未改动');
      }
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic>) {
        throw const FormatException('main(config) 必须返回配置对象');
      }
      return value;
    } finally {
      process.kill();
    }
  }

  static const _host = r'''
const vm = require('node:vm');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; if (input.length > 8*1024*1024) process.exit(2); });
process.stdin.on('end', () => {
 try {
  const data = JSON.parse(input);
  const context = vm.createContext(Object.create(null), {codeGeneration:{strings:false,wasm:false}});
  const expression = 'const config = JSON.parse(' + JSON.stringify(JSON.stringify(data.config)) + ');\n' +
    data.script + '\n;JSON.stringify(main(config));';
  const output = vm.runInContext(expression, context, {timeout:1500});
  if (typeof output !== 'string' || output.length > 4*1024*1024) process.exit(2);
  process.stdout.write(output);
 } catch (_) { process.exit(2); }
});
''';
}

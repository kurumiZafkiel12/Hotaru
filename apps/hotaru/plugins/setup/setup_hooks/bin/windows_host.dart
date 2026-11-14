import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:setup_hooks/src/build.dart';
import 'package:setup_hooks/src/logging.dart';
import 'package:setup_hooks/src/options.dart';
import 'package:setup_hooks/src/target.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length != 2) {
    throw ArgumentError(
      'Usage on Windows: windows_host.dart <app root> <output root>',
    );
  }
  final root = p.normalize(p.absolute(args[0]));
  final output = p.normalize(p.absolute(args[1]));
  if (!File(p.join(root, 'pubspec.yaml')).existsSync() ||
      !File(p.join(root, 'core', 'sing_box_host', 'go.mod')).existsSync()) {
    throw ArgumentError('The Hotaru application root is required');
  }
  initLogging();
  try {
    await buildPlatform(
      BuildRequest(
        rootDir: root,
        target: Target.windowsAmd64,
        engine: CoreBuildEngine.singBox,
        outputDir: output,
        harnessDir: p.join(root, 'plugins', 'setup', 'setup_hooks'),
      ),
    );
  } finally {
    closeLogging();
  }
}

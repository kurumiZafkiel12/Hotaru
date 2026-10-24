import 'dart:io';

/// The installer ships a pinned core alongside the application.
String bundledCorePath() => File(
  '${File(Platform.resolvedExecutable).parent.path}/core/${Platform.isWindows ? 'mihomo.exe' : 'mihomo'}',
).absolute.path;

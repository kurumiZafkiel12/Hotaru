import 'dart:convert';
import 'dart:io';

/// Writes text atomically: write a sibling temp file, flush, then rename
/// over the target. A crash mid-write can only corrupt the temp file; the
/// last good file stays intact. No temp file remains after success.
Future<void> writeTextAtomically(File file, String content) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(content, flush: true);
  try {
    await tmp.rename(file.path);
  } on FileSystemException {
    // Some Windows environments refuse rename-over-existing (locked or
    // replace-restricted targets). Fall back to delete-then-rename: a tiny
    // non-atomic window, still far better than failing the save outright.
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}

Future<void> writeJsonAtomically(File file, Object? data) =>
    writeTextAtomically(file, jsonEncode(data));

/// Default per-user data directory file, mirroring the layout file scheme:
/// Windows `%APPDATA%/Hotaru/<name>`, elsewhere `$HOME/Hotaru/<name>`.
/// The files stored here may contain node credentials: they stay in the
/// user's own profile directory and are never logged or uploaded.
File? userDataFile(String name) {
  final base = Platform.isWindows
      ? Platform.environment['APPDATA']
      : Platform.environment['HOME'];
  if (base == null) return null;
  return File('$base/Hotaru/$name');
}

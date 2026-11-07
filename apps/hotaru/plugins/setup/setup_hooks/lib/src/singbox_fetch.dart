import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'error.dart';
import 'target.dart';

final _log = Logger('singbox_fetch');

const _version = '1.14.4';

/// Places the official sing-box binary beside the Core for the beta data
/// plane. Only the Windows amd64 package exists in the beta; other targets
/// return null and ship without it.
Future<String?> fetchSingBox({
  required String rootDir,
  required Target target,
  required String outputDir,
}) async {
  if (target.goos != 'windows' || target.goarch != 'amd64') {
    return null;
  }
  const fileName = 'sing-box.exe';
  final outPath = p.join(rootDir, outputDir, target.platformDir, fileName);
  final cacheDir = Directory(
    p.join(rootDir, '.dart_tool', 'singbox', _version),
  );
  final cached = File(p.join(cacheDir.path, fileName));
  if (!cached.existsSync()) {
    await _download(cacheDir, cached);
  }
  await File(outPath).parent.create(recursive: true);
  await cached.copy(outPath);
  _log.info('sing-box $_version placed at $outPath');
  return outPath;
}

Future<void> _download(Directory cacheDir, File cached) async {
  const archive = 'sing-box-$_version-windows-amd64';
  const url =
      'https://github.com/SagerNet/sing-box/releases/download/'
      'v$_version/$archive.zip';
  await cacheDir.create(recursive: true);
  final zipFile = File(p.join(cacheDir.path, '$archive.zip'));
  _log.info('Downloading sing-box $_version from $url');
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw BuildException(
        'sing-box download failed: HTTP ${response.statusCode}',
      );
    }
    await response.pipe(zipFile.openWrite());
  } finally {
    client.close();
  }
  final extract = await Process.run('tar', [
    '-xf',
    zipFile.path,
    '-C',
    cacheDir.path,
  ]);
  if (extract.exitCode != 0) {
    throw BuildException('sing-box archive extract failed: ${extract.stderr}');
  }
  final extracted = File(p.join(cacheDir.path, archive, 'sing-box.exe'));
  if (!extracted.existsSync()) {
    throw BuildException('sing-box.exe missing from the release archive');
  }
  await extracted.rename(cached.path);
}

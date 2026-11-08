import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'error.dart';
import 'util.dart';

Future<
  ({Map<String, Object> metadata, List<String> inputs, List<String> outputs})
>
writeHostProvenance({
  required String rootDir,
  required String moduleDir,
  required String outputDir,
  required String target,
  required String helper,
}) async {
  final module = jsonDecode(
    runCommand('go', [
          'list',
          '-mod=readonly',
          '-m',
          '-json',
          'github.com/sagernet/sing-box',
        ], workingDirectory: moduleDir).stdout
        as String,
  );
  if (module is! Map ||
      module['Version'] != 'v1.14.4' ||
      module['Replace'] != null ||
      module['Dir'] is! String) {
    throw BuildException(
      'The host requires the pinned, unreplaced sing-box v1.14.4',
    );
  }
  final source = readSourceProvenance(rootDir);
  final revision = source.revision;
  final dirty = source.dirty;
  final upstreamLicense = p.join(module['Dir'] as String, 'LICENSE');
  final hostLicense = p.normalize(p.join(rootDir, '..', '..', 'LICENSE'));
  final upstreamOutput = p.join(outputDir, 'LICENSE-sing-box');
  final hostOutput = p.join(outputDir, 'LICENSE-Hotaru');
  copyFile(upstreamLicense, upstreamOutput);
  copyFile(hostLicense, hostOutput);
  final sources = p.join(outputDir, 'SOURCES.txt');
  File(sources).writeAsStringSync(
    'sing-box: https://github.com/SagerNet/sing-box/tree/v1.14.4\n'
    'Hotaru host: https://github.com/kurumiZafkiel12/Hotaru\n'
    'Source revision: $revision\n'
    'Working tree modified: $dirty\n',
    flush: true,
  );
  return (
    metadata: {
      'helperSha256': await calcSha256(helper),
      'target': target,
      'sourceCommit': revision,
      'sourceDirty': dirty,
    },
    inputs: [upstreamLicense, hostLicense, ...source.inputs],
    outputs: [upstreamOutput, hostOutput, sources],
  );
}

({String revision, bool dirty, List<String> inputs}) readSourceProvenance(
  String rootDir,
) {
  var revision = 'unversioned';
  var dirty = true;
  try {
    revision =
        (runCommand('git', [
                  'rev-parse',
                  'HEAD',
                ], workingDirectory: rootDir).stdout
                as String)
            .trim();
    if (!RegExp(r'^[a-f0-9]{40,64}$').hasMatch(revision)) {
      throw BuildException('Invalid source revision');
    }
    dirty =
        (runCommand('git', [
                  'status',
                  '--porcelain',
                  '--untracked-files=normal',
                ], workingDirectory: rootDir).stdout
                as String)
            .trim()
            .isNotEmpty;
  } on CommandFailedException {
    revision = 'unversioned';
  } on ProcessException {
    revision = 'unversioned';
  }
  String gitPath(String name) {
    final path =
        (runCommand('git', [
                  'rev-parse',
                  '--git-path',
                  name,
                ], workingDirectory: rootDir).stdout
                as String)
            .trim();
    return p.normalize(p.isAbsolute(path) ? path : p.join(rootDir, path));
  }

  final versionInputs = <String>[];
  if (revision != 'unversioned') {
    final branch =
        (runCommand('git', [
                  'rev-parse',
                  '--abbrev-ref',
                  'HEAD',
                ], workingDirectory: rootDir).stdout
                as String)
            .trim();
    versionInputs.addAll([
      gitPath('HEAD'),
      gitPath('packed-refs'),
      if (branch != 'HEAD') gitPath('refs/heads/$branch'),
    ]);
  }
  return (
    revision: revision,
    dirty: dirty,
    inputs: versionInputs.where((path) => File(path).existsSync()).toList(),
  );
}

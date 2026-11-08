import 'dart:io';
import 'dart:convert';

import 'package:hotaru/core/desktop/core_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('hotaru_manifest_test_');
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  test('reads the Core SHA256 from the runtime manifest', () async {
    const hash =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final file = File('${directory.path}/manifest.json')
      ..writeAsStringSync('{"coreSha256":"$hash"}');

    expect(await CoreManifest.readCoreSha256(path: file.path), hash);
  });

  test('rejects malformed or non-SHA256 manifest values', () async {
    final file = File('${directory.path}/manifest.json')
      ..writeAsStringSync('{"coreSha256":"not-a-sha256"}');

    expect(await CoreManifest.readCoreSha256(path: file.path), isNull);
  });

  test('returns null when the manifest is missing', () async {
    expect(
      await CoreManifest.readCoreSha256(
        path: '${directory.path}/missing-manifest.json',
      ),
      isNull,
    );
  });

  test('sing-box launch refuses the legacy bundle manifest', () async {
    final file = File('${directory.path}/manifest.json')
      ..writeAsStringSync(jsonEncode({'coreSha256': 'a' * 64}));
    expect(await CoreManifest.readSingBoxHostSha256(path: file.path), isNull);
  });

  test('requires the pinned engine version and bootstrap protocol', () async {
    for (final overrides in [
      {'engine': 'mihomo'},
      {'coreVersion': '1.14.3'},
      {'hostProtocol': 'unknown'},
      {'coreSha256': 'invalid'},
      <String, String>{},
    ]) {
      final file = File('${directory.path}/manifest.json')
        ..writeAsStringSync(
          jsonEncode({
            'engine': 'sing-box',
            'coreVersion': '1.14.4',
            'hostProtocol': 'hotaru-bootstrap-v1',
            'coreSha256': 'a' * 64,
            ...overrides,
          }),
        );
      expect(
        await CoreManifest.readSingBoxHostSha256(path: file.path),
        overrides.isEmpty ? 'a' * 64 : isNull,
      );
    }
  });
}

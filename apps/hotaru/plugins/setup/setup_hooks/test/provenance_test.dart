import 'dart:io';

import 'package:setup_hooks/src/provenance.dart';
import 'package:test/test.dart';

void main() {
  test('license notices are writable build outputs and can be refreshed', () {
    final directory = Directory.systemTemp.createTempSync('hotaru-notice-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final source = File('${directory.path}/upstream')
      ..writeAsStringSync('license one');
    final output = File('${directory.path}/build/LICENSE');
    writeLicenseNotice(source.path, output.path);
    if (Platform.isWindows) {
      expect(Process.runSync('attrib', ['+R', output.path]).exitCode, 0);
    }
    writeLicenseNotice(source.path, output.path);
    source.writeAsStringSync('license two');
    writeLicenseNotice(source.path, output.path);
    expect(output.readAsStringSync(), 'license two');
    output.writeAsStringSync('writable');
    expect(output.readAsStringSync(), 'writable');
  });
  test(
    'source archives without Git metadata remain explicitly unversioned',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'hotaru-source-archive-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final source = readSourceProvenance(directory.path);
      expect(source.revision, 'unversioned');
      expect(source.dirty, isTrue);
      expect(source.inputs, isEmpty);
    },
  );
}

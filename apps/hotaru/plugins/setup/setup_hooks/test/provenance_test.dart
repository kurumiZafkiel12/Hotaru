import 'dart:io';

import 'package:setup_hooks/src/provenance.dart';
import 'package:test/test.dart';

void main() {
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

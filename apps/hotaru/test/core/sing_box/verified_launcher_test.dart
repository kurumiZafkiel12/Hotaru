import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/sing_box/verified_launcher.dart';

class _Launcher implements CoreProcessLauncher {
  int calls = 0;
  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    calls++;
    throw StateError('verified launch reached');
  }
}

void main() {
  test(
    'direct launch verifies the actual file again before every spawn',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-integrity-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/host').writeAsBytes([1, 2, 3]);
      final delegate = _Launcher();
      final launcher = SingBoxVerifiedLauncher(
        executable: file.path,
        digest: sha256.convert([1, 2, 3]).toString(),
        launcher: delegate,
      );
      await expectLater(
        launcher.start(sessionId: 'first', address: 'pipe'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'verified launch reached',
          ),
        ),
      );
      expect(delegate.calls, 1);
      await file.writeAsBytes([3, 2, 1]);
      await expectLater(
        launcher.start(sessionId: 'second', address: 'pipe'),
        throwsStateError,
      );
      expect(delegate.calls, 1);
      await file.delete();
      await expectLater(
        launcher.start(sessionId: 'third', address: 'pipe'),
        throwsStateError,
      );
      expect(delegate.calls, 1);
    },
  );
}

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../desktop/model.dart';

final class SingBoxVerifiedLauncher implements CoreProcessLauncher {
  final String executable;
  final String digest;
  final CoreProcessLauncher launcher;

  const SingBoxVerifiedLauncher({
    required this.executable,
    required this.digest,
    required this.launcher,
  });

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    final path = executable;
    final expected = digest;
    final verified = await Isolate.run(() async {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) return false;
      try {
        return (await sha256.bind(File(path).openRead()).first).toString() ==
            expected;
      } on FileSystemException {
        return false;
      }
    });
    if (!verified) throw StateError('Bundled sing-box host integrity mismatch');
    return launcher.start(sessionId: sessionId, address: address);
  }
}

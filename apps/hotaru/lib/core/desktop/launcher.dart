import 'dart:convert';
import 'dart:io';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';

import 'model.dart';

import 'process_lease.dart';

export 'model.dart' show CoreProcessLauncher, DesktopCoreLauncherResolver;
export 'process_lease.dart' show CoreProcessStarter, DirectCoreLease;

final class DirectCoreLauncher implements CoreProcessLauncher {
  final CoreProcessStarter _startProcess;
  final String corePath;

  DirectCoreLauncher({CoreProcessStarter? startProcess, String? corePath})
    : _startProcess = startProcess ?? Process.start,
      corePath = corePath ?? appPath.corePath;

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    final process = await _startProcess(corePath, [address]);
    process.stdout.listen((_) {});
    process.stderr.listen((data) {
      final error = utf8.decode(data);
      if (error.isNotEmpty) {
        commonPrint.log(error, logLevel: LogLevel.warning);
      }
    });
    return DirectCoreLease(sessionId: sessionId, process: process);
  }
}

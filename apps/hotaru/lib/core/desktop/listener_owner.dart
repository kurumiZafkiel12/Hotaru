import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<int?> windowsListenerOwner(Uri endpoint) async {
  if (!Platform.isWindows ||
      !const ['127.0.0.1', '::1'].contains(endpoint.host) ||
      !endpoint.hasPort) {
    return null;
  }
  final command =
      "\$ErrorActionPreference='Stop'; "
      "(Get-NetTCPConnection -State Listen -LocalAddress '${endpoint.host}' "
      '-LocalPort ${endpoint.port} | Select-Object -ExpandProperty OwningProcess -Unique) -join ","';
  final process = await Process.start('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    command,
  ]);
  final output = utf8.decoder.bind(process.stdout).join();
  final errors = process.stderr.drain<void>();
  try {
    final status = await process.exitCode.timeout(const Duration(seconds: 5));
    final value = (await output).trim();
    await errors;
    return status == 0 && RegExp(r'^\d+$').hasMatch(value)
        ? int.tryParse(value)
        : null;
  } on TimeoutException {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 2));
    await output;
    await errors;
    return null;
  }
}

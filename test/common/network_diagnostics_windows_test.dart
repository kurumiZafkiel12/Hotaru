@TestOn('windows')
library;

import 'dart:io';

import 'package:hotaru/common/network_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

const _key =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

Future<({bool exists, String type, String value})> _snapshot(
  String name,
) async {
  final result = await Process.run('reg.exe', ['query', _key, '/v', name]);
  if (result.exitCode != 0) {
    return (exists: false, type: 'REG_SZ', value: '');
  }
  for (final line in '${result.stdout}'.split('\n')) {
    final match = RegExp(
      '^\\s*$name\\s+(REG_\\w+)\\s*(.*)\$',
    ).firstMatch(line.trimRight());
    if (match != null) {
      return (exists: true, type: match[1]!, value: match[2]!.trim());
    }
  }
  throw StateError('Registry value could not be parsed: $name');
}

void main() {
  test(
    'recovery clears actual Windows proxy/PAC values and restores the test host afterwards',
    () async {
      final proxy = await _snapshot('ProxyEnable');
      final pac = await _snapshot('AutoConfigURL');
      try {
        for (final (name, type, value) in [
          ('ProxyEnable', 'REG_DWORD', '1'),
          ('AutoConfigURL', 'REG_SZ', 'http://127.0.0.1:9/hotaru-test.pac'),
        ]) {
          final seeded = await Process.run('reg.exe', [
            'add',
            _key,
            '/v',
            name,
            '/t',
            type,
            '/d',
            value,
            '/f',
          ]);
          expect(seeded.exitCode, 0, reason: '${seeded.stderr}');
        }
        expect(await clearWindowsPac(Process.run), isTrue);
        expect((await _snapshot('ProxyEnable')).value.toLowerCase(), '0x0');
        expect((await _snapshot('AutoConfigURL')).value, isEmpty);
      } finally {
        for (final (name, saved) in [
          ('ProxyEnable', proxy),
          ('AutoConfigURL', pac),
        ]) {
          final restored = await Process.run(
            'reg.exe',
            saved.exists
                ? [
                    'add',
                    _key,
                    '/v',
                    name,
                    '/t',
                    saved.type,
                    '/d',
                    saved.value,
                    '/f',
                  ]
                : ['delete', _key, '/v', name, '/f'],
          );
          expect(
            restored.exitCode,
            0,
            reason: 'restore $name: ${restored.stderr}',
          );
        }
      }
    },
  );
}

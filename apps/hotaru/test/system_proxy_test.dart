import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/platform/system_proxy.dart';

void main() {
  test(
    'Windows proxy changes broadcast refresh after registry writes',
    () async {
      var refreshed = 0;
      final proxy = WindowsSystemProxy(
        run: (_) async => ProcessResult(0, 0, '', ''),
        notify: () => refreshed++,
      );
      await proxy.enable('127.0.0.1:7890');
      await proxy.restore(const SavedProxyState(enable: false));
      expect(refreshed, 2);
    },
  );
  test('parse reg query output for DWORD and SZ values', () {
    const out = '''

HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x1
''';
    expect(WindowsSystemProxy.parseQueryValue(out, 'ProxyEnable'), '0x1');
    const out2 = '    ProxyServer    REG_SZ    127.0.0.1:7890\r\n';
    expect(
      WindowsSystemProxy.parseQueryValue(out2, 'ProxyServer'),
      '127.0.0.1:7890',
    );
    expect(WindowsSystemProxy.parseQueryValue(out2, 'Missing'), isNull);
    expect(WindowsSystemProxy.parseQueryValue('', 'ProxyEnable'), isNull);
  });

  test('read/enable/restore issue the expected reg commands', () async {
    final calls = <List<String>>[];
    Future<ProcessResult> fakeRun(List<String> args) async {
      calls.add(args);
      if (args.first == 'query' && args.last == 'ProxyEnable') {
        return ProcessResult(0, 0, '    ProxyEnable    REG_DWORD    0x0\n', '');
      }
      if (args.first == 'query' && args.last == 'ProxyServer') {
        return ProcessResult(
          0,
          0,
          '    ProxyServer    REG_SZ    old.example:8080\n',
          '',
        );
      }
      return ProcessResult(0, 0, '', '');
    }

    final proxy = WindowsSystemProxy(run: fakeRun);
    final before = await proxy.read();
    expect(before.enable, isFalse);
    expect(before.server, 'old.example:8080');

    await proxy.enable('127.0.0.1:7890');
    expect(calls.where((c) => c.first == 'add').map((c) => c[3]).toList(), [
      'ProxyServer',
      'ProxyEnable',
    ]);

    await proxy.restore(before);
    final adds = calls.where((c) => c.first == 'add').toList();
    // Restore writes the ORIGINAL values back, not Hotaru's.
    expect(adds[adds.length - 2][7], 'old.example:8080');
    expect(adds.last[7], '0');
  });

  test('restore deletes values that were originally absent', () async {
    final verbs = <String>[];
    Future<ProcessResult> fakeRun(List<String> args) async {
      verbs.add(args.first);
      return ProcessResult(0, 0, '', '');
    }

    final proxy = WindowsSystemProxy(run: fakeRun);
    await proxy.restore(const SavedProxyState());
    expect(verbs, ['delete', 'add', 'delete', 'delete']);
  });

  test('saved state round-trips through JSON', () {
    const state = SavedProxyState(enable: true, server: 'a:1');
    final back = SavedProxyState.decode(state.encode());
    expect(back.enable, isTrue);
    expect(back.server, 'a:1');
    const empty = SavedProxyState();
    final back2 = SavedProxyState.decode(empty.encode());
    expect(back2.enable, isNull);
    expect(back2.server, isNull);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:ffi';

/// The user's pre-existing Windows per-user proxy settings, captured before
/// Hotaru touches anything so they can be restored exactly.
class SavedProxyState {
  final bool? enable; // null = value absent
  final String? server; // null = value absent

  const SavedProxyState({this.enable, this.server});

  Map<String, dynamic> toJson() => {'enable': enable, 'server': server};

  factory SavedProxyState.fromJson(Map<String, dynamic> json) =>
      SavedProxyState(
        enable: json['enable'] as bool?,
        server: json['server'] as String?,
      );

  String encode() => jsonEncode(toJson());

  static SavedProxyState decode(String text) =>
      SavedProxyState.fromJson(jsonDecode(text) as Map<String, dynamic>);
}

/// Reads and changes the *current user's* Windows Internet Settings proxy.
///
/// Contract: [enable] must only be called after the caller has persisted
/// the state returned by [read] somewhere crash-safe; [restore] puts that
/// exact state back (including "value absent"). Hotaru never invents a
/// "default" to restore to.
abstract class SystemProxyAdapter {
  Future<SavedProxyState> read();
  Future<void> enable(String server);
  Future<void> restore(SavedProxyState saved);

  static SystemProxyAdapter forPlatform() {
    if (Platform.isWindows) return WindowsSystemProxy();
    return UnsupportedSystemProxy();
  }

  static bool get isSupported => Platform.isWindows;
}

class UnsupportedSystemProxy implements SystemProxyAdapter {
  @override
  Future<SavedProxyState> read() =>
      throw UnsupportedError('System proxy is Windows-only in this stage');

  @override
  Future<void> enable(String server) =>
      throw UnsupportedError('System proxy is Windows-only in this stage');

  @override
  Future<void> restore(SavedProxyState saved) =>
      throw UnsupportedError('System proxy is Windows-only in this stage');
}

class WindowsSystemProxy implements SystemProxyAdapter {
  static const key =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  final Future<ProcessResult> Function(List<String> args) _run;
  final void Function() _notify;

  WindowsSystemProxy({
    Future<ProcessResult> Function(List<String> args)? run,
    void Function()? notify,
  }) : _run = run ?? _defaultRun,
       _notify = notify ?? (run == null ? notifyWindows : () {});

  static void notifyWindows() {
    if (!Platform.isWindows) return;
    final setOption = DynamicLibrary.open('wininet.dll')
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Void>, int)
        >('InternetSetOptionW');
    if (setOption(nullptr, 39, nullptr, 0) == 0 ||
        setOption(nullptr, 37, nullptr, 0) == 0) {
      throw StateError('Windows proxy refresh failed');
    }
  }

  static Future<ProcessResult> _defaultRun(List<String> args) =>
      Process.run('reg', args, runInShell: false);

  /// Parses one value out of `reg query` output, e.g.
  /// `    ProxyServer    REG_SZ    127.0.0.1:7890` → `127.0.0.1:7890`,
  /// `    ProxyEnable    REG_DWORD    0x1` → `1`. Null when absent.
  static String? parseQueryValue(String output, String valueName) {
    for (final line in output.split(RegExp(r'\r?\n'))) {
      final match = RegExp(
        '^\\s*${RegExp.escape(valueName)}\\s+REG_\\w+\\s+(.*?)\\s*\$',
      ).firstMatch(line);
      if (match != null) return match.group(1);
    }
    return null;
  }

  Future<String> _query(String valueName) async {
    final result = await _run(['query', key, '/v', valueName]);
    if (result.exitCode != 0) return ''; // value absent
    return result.stdout as String;
  }

  @override
  Future<SavedProxyState> read() async {
    final enableRaw = parseQueryValue(
      await _query('ProxyEnable'),
      'ProxyEnable',
    );
    final serverRaw = parseQueryValue(
      await _query('ProxyServer'),
      'ProxyServer',
    );
    return SavedProxyState(
      enable: enableRaw == null ? null : enableRaw == '0x1' || enableRaw == '1',
      server: serverRaw,
    );
  }

  Future<void> _add(String name, String type, String data) async {
    final result = await _run([
      'add',
      key,
      '/v',
      name,
      '/t',
      type,
      '/d',
      data,
      '/f',
    ]);
    if (result.exitCode != 0) {
      throw StateError('reg add $name failed: ${result.stderr}');
    }
  }

  Future<void> _delete(String name) async {
    final result = await _run(['delete', key, '/v', name, '/f']);
    if (result.exitCode != 0 && result.exitCode != 1) {
      throw StateError('reg delete $name failed: ${result.stderr}');
    }
  }

  @override
  Future<void> enable(String server) async {
    await _add('ProxyServer', 'REG_SZ', server);
    await _add('ProxyEnable', 'REG_DWORD', '1');
    _notify();
  }

  @override
  Future<void> restore(SavedProxyState saved) async {
    if (saved.server == null) {
      await _delete('ProxyServer');
    } else {
      await _add('ProxyServer', 'REG_SZ', saved.server!);
    }
    if (saved.enable == null) {
      await _delete('ProxyEnable');
    } else {
      await _add('ProxyEnable', 'REG_DWORD', saved.enable! ? '1' : '0');
    }
    _notify();
  }
}

import 'dart:ffi';

final class WindowsProcessWitness {
  WindowsProcessWitness._(this._handle);

  static final _library = DynamicLibrary.open('kernel32.dll');
  static final _open = _library
      .lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)
      >('OpenProcess');
  static final _wait = _library
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');
  static final _close = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  static final _error = _library
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  // Retain the original process object across replacement, rather than observing
  // a PID that Windows may recycle before the assertion runs.
  factory WindowsProcessWitness.open(int pid) {
    final handle = _open(0x100000, 0, pid);
    if (handle == nullptr) {
      throw StateError('Cannot witness process $pid: ${_error()}');
    }
    return WindowsProcessWitness._(handle);
  }

  Pointer<Void> _handle;

  bool get hasExited {
    if (_handle == nullptr) throw StateError('Process witness is closed');
    final result = _wait(_handle, 0);
    if (result == 0) return true;
    if (result == 258) return false;
    throw StateError('Cannot observe process exit: ${_error()}');
  }

  void close() {
    if (_handle == nullptr) return;
    _close(_handle);
    _handle = nullptr;
  }
}

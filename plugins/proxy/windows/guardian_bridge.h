#pragma once
#include <windows.h>
#include <string>

namespace hotaru_guard {
inline HANDLE restore = nullptr;
inline HANDLE done = nullptr;
inline HANDLE failed = nullptr;
inline int owned_port = 0;

inline bool Stop() {
  if (!restore) return true;
  SetEvent(restore);
  const bool finished = WaitForSingleObject(done, 6000) == WAIT_OBJECT_0;
  if (!finished) return false;
  const bool success = WaitForSingleObject(failed, 0) != WAIT_OBJECT_0;
  CloseHandle(restore);
  CloseHandle(done);
  CloseHandle(failed);
  restore = done = failed = nullptr;
  owned_port = 0;
  return success;
}

inline bool Arm(int port) {
  if (restore && owned_port == port) return true;
  if (!Stop()) return false;
  wchar_t module[32768]{};
  const DWORD length = GetModuleFileNameW(nullptr, module, 32768);
  if (!length || length >= 32768) return false;
  const std::wstring main_path(module);
  const auto separator = main_path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return false;
  const auto executable = main_path.substr(0, separator + 1) + L"HotaruProxyGuardian.exe";
  const auto pid = std::to_wstring(GetCurrentProcessId());
  const auto token = pid + L"-" + std::to_wstring(GetTickCount64());
  const auto prefix = L"Local\\HotaruGuard-" + token;
  std::wstring command = L"\"" + executable + L"\" arm " + token + L" " + pid + L" " + pid + L" 127.0.0.1:" + std::to_wstring(port);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION child{};
  if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child)) return false;
  const auto wait = WaitForSingleObject(child.hProcess, 6000);
  DWORD code = 1;
  if (wait == WAIT_OBJECT_0) GetExitCodeProcess(child.hProcess, &code);
  CloseHandle(child.hThread);
  CloseHandle(child.hProcess);
  if (code != 0) return false;
  restore = OpenEventW(EVENT_MODIFY_STATE, FALSE, (prefix + L"-restore").c_str());
  done = OpenEventW(SYNCHRONIZE, FALSE, (prefix + L"-done").c_str());
  failed = OpenEventW(SYNCHRONIZE, FALSE, (prefix + L"-failed").c_str());
  if (!restore || !done || !failed) {
    if (restore) CloseHandle(restore);
    if (done) CloseHandle(done);
    if (failed) CloseHandle(failed);
    restore = done = failed = nullptr;
    return false;
  }
  owned_port = port;
  return true;
}
}

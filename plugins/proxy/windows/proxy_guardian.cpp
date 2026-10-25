// Independent same-user guardian. Never installs or runs as administrator.
#include <windows.h>
#include <wininet.h>
#include <string>
#include <vector>
#include <cwchar>
#include <cstring>
#pragma comment(lib, "advapi32.lib")

constexpr auto kKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
struct Value {
  bool exists = false;
  DWORD type = 0;
  std::vector<BYTE> data;
};
Value Read(HKEY key, const wchar_t* name) {
  Value v;
  DWORD size = 0;
  if (RegQueryValueExW(key, name, nullptr, &v.type, nullptr, &size) != ERROR_SUCCESS) return v;
  v.data.resize(size);
  if (RegQueryValueExW(key, name, nullptr, &v.type, v.data.data(), &size) == ERROR_SUCCESS) v.exists = true;
  return v;
}
bool Restore(HKEY key, const wchar_t* name, const Value& v) {
  const auto code = v.exists ? RegSetValueExW(key, name, 0, v.type, v.data.data(), static_cast<DWORD>(v.data.size()))
                            : RegDeleteValueW(key, name);
  return code == ERROR_SUCCESS || code == ERROR_FILE_NOT_FOUND;
}
DWORD DetachedFlags(const wchar_t* parent_pid) {
  const auto name = L"Local\\HotaruCoreJob-" + std::wstring(parent_pid);
  HANDLE job = OpenJobObjectW(JOB_OBJECT_QUERY, FALSE, name.c_str());
  BOOL inherited = FALSE;
  if (job) { IsProcessInJob(GetCurrentProcess(), job, &inherited); CloseHandle(job); }
  // A CI/terminal host may own a different job that forbids breakaway. Such
  // a job does not close when the UI/test parent exits. Escape only our job.
  return CREATE_NO_WINDOW | (inherited ? CREATE_BREAKAWAY_FROM_JOB : 0);
}
int wmain(int argc, wchar_t** argv) {
  if (argc < 3) return 2;
  if (argc == 4 && (std::wstring(argv[1]) == L"update" || std::wstring(argv[1]) == L"apply")) {
    const bool launch = std::wstring(argv[1]) == L"update";
    if (!launch) {
      HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, wcstoul(argv[2], nullptr, 10));
      if (parent) {
        const auto result = WaitForSingleObject(parent, 300000);
        CloseHandle(parent);
        if (result != WAIT_OBJECT_0) return 3;
      }
    }
    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    const std::wstring path = launch ? std::wstring(exe) : std::wstring(argv[3]);
    std::wstring command = L"\"" + path + L"\"" + (launch ? L" apply " + std::wstring(argv[2]) + L" \"" + argv[3] + L"\"" : L" /SILENT /NORESTART");
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    const bool created = CreateProcessW(path.c_str(), command.data(), nullptr, nullptr, FALSE,
      launch ? DetachedFlags(argv[2]) : CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process) != FALSE;
    if (created) { CloseHandle(process.hThread); CloseHandle(process.hProcess); }
    return created ? 0 : 3;
  }
  const std::wstring action = argv[1], token = argv[2];
  if (token.size() > 96 || token.find_first_not_of(L"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-") != std::wstring::npos) return 2;
  const std::wstring prefix = L"Local\\HotaruGuard-" + token;
  if (action == L"cancel") {
    HANDLE cancel = OpenEventW(EVENT_MODIFY_STATE, FALSE, (prefix + L"-cancel").c_str());
    HANDLE done = OpenEventW(SYNCHRONIZE, FALSE, (prefix + L"-done").c_str());
    if (!cancel) return 0; // Already completed after core death.
    SetEvent(cancel);
    const auto wait = done ? WaitForSingleObject(done, 5000) : WAIT_OBJECT_0;
    CloseHandle(cancel);
    if (done) CloseHandle(done);
    return wait == WAIT_OBJECT_0 ? 0 : 3;
  }
  if (argc != 6) return 2;
  if (action == L"arm") {
    HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, (prefix + L"-ready").c_str());
    if (!ready || GetLastError() == ERROR_ALREADY_EXISTS) return 3;
    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring command = L"\"" + std::wstring(exe) + L"\" watch " + token + L" " + argv[3] + L" " + argv[4] + L" " + argv[5];
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    // Escapes only Hotaru's job, leaving the core in the kill-on-close job.
    const bool created = CreateProcessW(exe, command.data(), nullptr, nullptr, FALSE,
      DetachedFlags(argv[3]), nullptr, nullptr, &startup, &process) != FALSE;
    DWORD result = WAIT_FAILED;
    if (created) {
      HANDLE handles[] = {ready, process.hProcess};
      result = WaitForMultipleObjects(2, handles, FALSE, 5000);
      if (result != WAIT_OBJECT_0) TerminateProcess(process.hProcess, 3);
      CloseHandle(process.hThread); CloseHandle(process.hProcess);
    }
    CloseHandle(ready);
    return result == WAIT_OBJECT_0 ? 0 : 3;
  }
  if (action != L"watch") return 2;
  HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, wcstoul(argv[3], nullptr, 10));
  HANDLE core = OpenProcess(SYNCHRONIZE, FALSE, wcstoul(argv[4], nullptr, 10));
  HANDLE cancel = CreateEventW(nullptr, TRUE, FALSE, (prefix + L"-cancel").c_str());
  HANDLE restore = CreateEventW(nullptr, TRUE, FALSE, (prefix + L"-restore").c_str());
  HANDLE done = CreateEventW(nullptr, TRUE, FALSE, (prefix + L"-done").c_str());
  HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, (prefix + L"-ready").c_str());
  HKEY key = nullptr;
  if (!parent || !core || !cancel || !restore || !done || !ready ||
      RegOpenKeyExW(HKEY_CURRENT_USER, kKey, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, &key) != ERROR_SUCCESS) return 3;
  const Value enable = Read(key, L"ProxyEnable"), server = Read(key, L"ProxyServer"), bypass = Read(key, L"ProxyOverride");
  SetEvent(ready);
  HANDLE handles[] = {cancel, parent, core, restore};
  const auto result = WaitForMultipleObjects(4, handles, FALSE, INFINITE);
  bool ok = true;
  if (result == WAIT_OBJECT_0 + 1 || result == WAIT_OBJECT_0 + 2 || result == WAIT_OBJECT_0 + 3) {
    const Value currentEnable = Read(key, L"ProxyEnable"), currentServer = Read(key, L"ProxyServer");
    const std::wstring owned = argv[5];
    const auto expectedSize = (owned.size() + 1) * sizeof(wchar_t);
    if (currentEnable.exists && currentEnable.type == REG_DWORD && currentEnable.data.size() == sizeof(DWORD) &&
        *reinterpret_cast<const DWORD*>(currentEnable.data.data()) == 1 &&
        currentServer.exists && currentServer.type == REG_SZ && currentServer.data.size() == expectedSize &&
        memcmp(currentServer.data.data(), owned.c_str(), expectedSize) == 0) {
      // Restore endpoint first so a partial failure cannot keep a dead local endpoint.
      ok = Restore(key, L"ProxyServer", server);
      ok = Restore(key, L"ProxyEnable", enable) && ok;
      ok = Restore(key, L"ProxyOverride", bypass) && ok;
      // Load WinINet only after capturing the snapshot. Its initialization or
      // refresh may materialize absent default values on a fresh account.
      HMODULE internet = LoadLibraryW(L"wininet.dll");
      if (internet) {
        using SetOption = BOOL(WINAPI*)(HINTERNET, DWORD, LPVOID, DWORD);
        const auto notify = reinterpret_cast<SetOption>(GetProcAddress(internet, "InternetSetOptionW"));
        if (notify) {
          notify(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
          notify(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
        }
        FreeLibrary(internet);
      }
      if (!server.exists) ok = Restore(key, L"ProxyServer", server) && ok;
      if (!enable.exists) ok = Restore(key, L"ProxyEnable", enable) && ok;
      ok = Restore(key, L"ProxyOverride", bypass) && ok;
    }
  }
  RegCloseKey(key);
  SetEvent(done);
  for (const auto handle : {parent, core, cancel, restore, done, ready}) CloseHandle(handle);
  return ok ? 0 : 4;
}

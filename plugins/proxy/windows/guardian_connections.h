#pragma once
#include <windows.h>
#include <wininet.h>
#include <ras.h>
#include <string>
#include <vector>

struct GuardConnection {
  std::wstring name, server, bypass;
  DWORD flags = PROXY_TYPE_DIRECT;
};
class GuardConnections {
 public:
  bool Capture() {
    internet_ = LoadLibraryW(L"wininet.dll");
    if (!internet_) return false;
    query_ = reinterpret_cast<Query>(GetProcAddress(internet_, "InternetQueryOptionW"));
    set_ = reinterpret_cast<Set>(GetProcAddress(internet_, "InternetSetOptionW"));
    if (!query_ || !set_) return false;
    GuardConnection local;
    if (!Get(&local)) return false;
    snapshots_.push_back(local);
    HMODULE ras = LoadLibraryW(L"rasapi32.dll");
    if (!ras) return false;
    using Enumerate = DWORD(WINAPI*)(LPCWSTR, LPCWSTR, LPRASENTRYNAMEW, LPDWORD, LPDWORD);
    const auto enumerate = reinterpret_cast<Enumerate>(GetProcAddress(ras, "RasEnumEntriesW"));
    bool ok = enumerate != nullptr;
    if (enumerate) {
      DWORD size = sizeof(RASENTRYNAMEW), count = 0, code = ERROR_BUFFER_TOO_SMALL;
      std::vector<BYTE> buffer;
      for (int attempt = 0; attempt < 4 && code == ERROR_BUFFER_TOO_SMALL; ++attempt) {
        buffer.resize(size);
        auto entries = reinterpret_cast<LPRASENTRYNAMEW>(buffer.data());
        entries[0].dwSize = sizeof(RASENTRYNAMEW);
        code = enumerate(nullptr, nullptr, entries, &size, &count);
      }
      ok = code == ERROR_SUCCESS;
      if (ok) {
        const auto entries = reinterpret_cast<LPRASENTRYNAMEW>(buffer.data());
        for (DWORD i = 0; i < count; ++i) {
          GuardConnection connection;
          connection.name = entries[i].szEntryName;
          if (!Get(&connection)) { ok = false; break; }
          snapshots_.push_back(connection);
        }
      }
    }
    FreeLibrary(ras);
    return ok;
  }
  bool Recover(const std::wstring& owned, bool ownsLocal) {
    bool ok = true;
    for (const auto& snapshot : snapshots_) {
      if (snapshot.name.empty() && !ownsLocal) continue;
      GuardConnection current;
      current.name = snapshot.name;
      if (!Get(&current)) { ok = false; continue; }
      if ((current.flags & PROXY_TYPE_PROXY) == 0 || current.server != owned) continue;
      INTERNET_PER_CONN_OPTIONW options[3]{};
      options[0].dwOption = INTERNET_PER_CONN_FLAGS;
      options[0].Value.dwValue = snapshot.flags;
      options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
      options[1].Value.pszValue = const_cast<wchar_t*>(snapshot.server.c_str());
      options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
      options[2].Value.pszValue = const_cast<wchar_t*>(snapshot.bypass.c_str());
      auto list = List(snapshot.name, options);
      ok = (set_(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list)) != FALSE) && ok;
    }
    return ok;
  }
  void Notify() {
    set_(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
    set_(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  }
  ~GuardConnections() { if (internet_) FreeLibrary(internet_); }
 private:
  using Query = BOOL(WINAPI*)(HINTERNET, DWORD, LPVOID, LPDWORD);
  using Set = BOOL(WINAPI*)(HINTERNET, DWORD, LPVOID, DWORD);
  HMODULE internet_ = nullptr;
  Query query_ = nullptr;
  Set set_ = nullptr;
  std::vector<GuardConnection> snapshots_;
  static INTERNET_PER_CONN_OPTION_LISTW List(const std::wstring& name, INTERNET_PER_CONN_OPTIONW* options) {
    INTERNET_PER_CONN_OPTION_LISTW list{};
    list.dwSize = sizeof(list);
    list.pszConnection = name.empty() ? nullptr : const_cast<wchar_t*>(name.c_str());
    list.dwOptionCount = 3;
    list.pOptions = options;
    return list;
  }
  bool Get(GuardConnection* value) {
    INTERNET_PER_CONN_OPTIONW options[3]{};
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    auto list = List(value->name, options);
    DWORD size = sizeof(list);
    const bool ok = query_(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size) != FALSE;
    if (ok) {
      value->flags = options[0].Value.dwValue;
      if (options[1].Value.pszValue) value->server = options[1].Value.pszValue;
      if (options[2].Value.pszValue) value->bypass = options[2].Value.pszValue;
    }
    if (options[1].Value.pszValue) GlobalFree(options[1].Value.pszValue);
    if (options[2].Value.pszValue) GlobalFree(options[2].Value.pszValue);
    return ok;
  }
};

// Phase-one Windows SCM host. Runs the fixed bundled core as LocalService,
// never as SYSTEM. Only the installing user's SID can access the local pipe.
// TUN stays disabled until a separately reviewed privileged network broker exists.
#include <windows.h>
#include <sddl.h>
#include <aclapi.h>
#include <string>
#include <vector>
#include <fstream>
#include <filesystem>
#include <iostream>
#include <algorithm>
#pragma comment(lib, "advapi32.lib")
constexpr auto kService = L"HotaruCoreHost";
constexpr auto kPipe = L"\\\\.\\pipe\\HotaruCoreHost-v1";
constexpr auto kParams = L"SYSTEM\\CurrentControlSet\\Services\\HotaruCoreHost\\Parameters";
SERVICE_STATUS_HANDLE status_handle = nullptr;
HANDLE stop_event = nullptr;
std::wstring owner;

std::wstring Exe() { wchar_t value[32768]{}; GetModuleFileNameW(nullptr, value, 32768); return value; }
std::wstring ReadOwner() {
  wchar_t value[256]{}; DWORD bytes = sizeof(value);
  return RegGetValueW(HKEY_LOCAL_MACHINE, kParams, L"Owner", RRF_RT_REG_SZ, nullptr, value, &bytes) == ERROR_SUCCESS ? value : L"";
}
void Status(DWORD state, DWORD code = NO_ERROR) {
  SERVICE_STATUS s{}; s.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  s.dwCurrentState = state; s.dwWin32ExitCode = code;
  s.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
  SetServiceStatus(status_handle, &s);
}
void WINAPI Control(DWORD code) {
  if (code == SERVICE_CONTROL_STOP || code == SERVICE_CONTROL_SHUTDOWN) SetEvent(stop_event);
}
bool Transfer(HANDLE pipe, void* buffer, DWORD size, bool write) {
  auto bytes = static_cast<BYTE*>(buffer);
  while (size > 0) {
    DWORD count = 0;
    const bool ok = write ? WriteFile(pipe, bytes, size, &count, nullptr) != FALSE : ReadFile(pipe, bytes, size, &count, nullptr) != FALSE;
    if (!ok || count == 0) return false;
    size -= count; bytes += count;
  }
  return true;
}

void Serve(HANDLE pipe, const std::filesystem::path& base) {
  // Owner-only pipe already authenticated this local caller. Limit input and
  // wait for the header without indefinitely blocking service shutdown.
  DWORD available = 0;
  const auto deadline = GetTickCount64() + 10000;
  while (available < sizeof(DWORD) && GetTickCount64() < deadline) {
    if (WaitForSingleObject(stop_event, 50) == WAIT_OBJECT_0 || !PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) return;
  }
  DWORD size = 0;
  if (available < sizeof(DWORD) || !Transfer(pipe, &size, sizeof(size), false) || size == 0 || size > 4 * 1024 * 1024) return;
  std::string config(size, '\0');
  // Small bounded chunks with a deadline; a stalled client cannot pin the service.
  DWORD read = 0;
  while (read < size && GetTickCount64() < deadline) {
    if (WaitForSingleObject(stop_event, 10) == WAIT_OBJECT_0 || !PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) return;
    if (!available) continue;
    const auto part = (std::min)(available, size - read);
    if (!Transfer(pipe, config.data() + read, part, false)) return;
    read += part;
  }
  if (read != size) return;
  // Do not accept arbitrary executables, command lines, environment or paths.
  // File writes requested by Mihomo remain within LocalService's OS rights.
  const auto runtime = base / L"runtime";
  std::error_code ec; std::filesystem::create_directories(runtime, ec);
  const auto file = runtime / L"config.json";
  { std::ofstream output(file, std::ios::binary | std::ios::trunc); output.write(config.data(), config.size()); if (!output) return; }
  const auto executable = std::filesystem::path(Exe()).parent_path() / L"core" / L"mihomo.exe";
  std::wstring command = L"\"" + executable.wstring() + L"\" -d \"" + runtime.wstring() + L"\" -f \"" + file.wstring() + L"\"";
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{}; limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) { if (job) CloseHandle(job); return; }
  STARTUPINFOW startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION child{};
  const bool created = CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW | CREATE_SUSPENDED,
      nullptr, runtime.c_str(), &startup, &child) != FALSE;
  if (created) {
    if (AssignProcessToJobObject(job, child.hProcess)) ResumeThread(child.hThread); else TerminateProcess(child.hProcess, 3);
    CloseHandle(child.hThread);
    DWORD ack = 1;
    Transfer(pipe, &ack, sizeof(ack), true);
    // The client wrapper's lifetime is the lease. App death kills that wrapper
    // in the UI job, disconnects this pipe, and tears down the service core.
    while (WaitForSingleObject(stop_event, 100) != WAIT_OBJECT_0 && WaitForSingleObject(child.hProcess, 0) == WAIT_TIMEOUT) {
      if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) break;
      if (available) break; // Any further byte means release the lease.
    }
    TerminateProcess(child.hProcess, 0);
    WaitForSingleObject(child.hProcess, 5000);
    CloseHandle(child.hProcess);
  }
  CloseHandle(job);
  DeleteFileW(file.c_str());
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
  status_handle = RegisterServiceCtrlHandlerW(kService, Control);
  if (!status_handle) return;
  Status(SERVICE_START_PENDING);
  stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  owner = ReadOwner();
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  const auto dacl = L"D:P(A;;GA;;;SY)(A;;GA;;;LS)(A;;GA;;;" + owner + L")";
  if (!stop_event || owner.empty() || !ConvertStringSecurityDescriptorToSecurityDescriptorW(dacl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) { Status(SERVICE_STOPPED, ERROR_ACCESS_DENIED); return; }
  SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
  wchar_t program_data[32768]{}; GetEnvironmentVariableW(L"ProgramData", program_data, 32768);
  const auto base = std::filesystem::path(program_data) / L"HotaruCoreHost";
  Status(SERVICE_RUNNING);
  while (WaitForSingleObject(stop_event, 0) != WAIT_OBJECT_0) {
    HANDLE pipe = CreateNamedPipeW(kPipe, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, &security);
    if (pipe == INVALID_HANDLE_VALUE) break;
    bool connected = false;
    while (WaitForSingleObject(stop_event, 50) != WAIT_OBJECT_0) {
      if (ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED) { connected = true; break; }
    }
    if (connected) {
      DWORD mode = PIPE_READMODE_BYTE | PIPE_WAIT;
      SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);
      Serve(pipe, base);
    }
    DisconnectNamedPipe(pipe); CloseHandle(pipe);
  }
  LocalFree(descriptor); CloseHandle(stop_event);
  Status(SERVICE_STOPPED);
}

int Install(const std::wstring& sid) {
  PSID parsed = nullptr;
  if (!ConvertStringSidToSidW(sid.c_str(), &parsed) || !IsValidSid(parsed)) return 2;
  LocalFree(parsed);
  wchar_t program_files[32768]{}, program_data[32768]{};
  GetEnvironmentVariableW(L"ProgramFiles", program_files, 32768);
  GetEnvironmentVariableW(L"ProgramData", program_data, 32768);
  const auto target = std::filesystem::path(program_files) / L"HotaruCoreHost";
  const auto data = std::filesystem::path(program_data) / L"HotaruCoreHost";
  std::error_code ec;
  for (const auto& dir : {target, data}) {
    std::filesystem::create_directories(dir, ec);
    if (ec || (GetFileAttributesW(dir.c_str()) & FILE_ATTRIBUTE_REPARSE_POINT)) return 3;
  }
  // Lock both directories before publishing any service executable/config.
  for (const auto& dir : {target, data}) {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const auto sddl = dir == target ? L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;LS)(A;OICI;GRGX;;;BU)"
                                    : L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;LS)";
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &descriptor, nullptr)) return 3;
    const auto ok = SetFileSecurityW(dir.c_str(), DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, descriptor);
    LocalFree(descriptor); if (!ok) return 3;
  }
  std::filesystem::create_directories(target / L"core", ec); if (ec) return 3;
  const auto source = std::filesystem::path(Exe()).parent_path();
  if (!CopyFileW(Exe().c_str(), (target / L"Hotaru.Service.exe").c_str(), FALSE) ||
      !CopyFileW((source / L"core" / L"mihomo.exe").c_str(), (target / L"core" / L"mihomo.exe").c_str(), FALSE)) return 3;
  // Copy app-local VC runtime so LocalService does not rely on a user install.
  for (const auto dll : {L"msvcp140.dll", L"vcruntime140.dll", L"vcruntime140_1.dll"}) {
    if (!CopyFileW((source / dll).c_str(), (target / dll).c_str(), FALSE)) return 3;
  }
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CREATE_SERVICE);
  if (!scm) return 3;
  const auto command = L"\"" + (target / L"Hotaru.Service.exe").wstring() + L"\" service";
  SC_HANDLE service = CreateServiceW(scm, kService, L"Hotaru Core Host", SERVICE_ALL_ACCESS,
    SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL, command.c_str(), nullptr, nullptr,
    nullptr, L"NT AUTHORITY\\LocalService", nullptr);
  if (!service) { CloseServiceHandle(scm); return 3; }
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, kParams, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    DeleteService(service); CloseServiceHandle(service); CloseServiceHandle(scm); return 3;
  }
  RegSetValueExW(key, L"Owner", 0, REG_SZ, reinterpret_cast<const BYTE*>(sid.c_str()), static_cast<DWORD>((sid.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  const bool ok = StartServiceW(service, 0, nullptr) != FALSE;
  CloseServiceHandle(service); CloseServiceHandle(scm);
  return ok ? 0 : 3;
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 2) return 2;
  const std::wstring action = argv[1];
  if (action == L"service") {
    SERVICE_TABLE_ENTRYW entries[] = {{const_cast<wchar_t*>(kService), ServiceMain}, {nullptr, nullptr}};
    return StartServiceCtrlDispatcherW(entries) ? 0 : 3;
  }
  if (action == L"install" && argc == 3) return Install(argv[2]);
  if (action == L"remove") {
    SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    SC_HANDLE item = manager ? OpenServiceW(manager, kService, SERVICE_STOP | DELETE | SERVICE_QUERY_STATUS) : nullptr;
    if (!item) { if (manager) CloseServiceHandle(manager); return 3; }
    SERVICE_STATUS stopped{}; ControlService(item, SERVICE_CONTROL_STOP, &stopped);
    const bool deleted = DeleteService(item) != FALSE;
    CloseServiceHandle(item); CloseServiceHandle(manager); return deleted ? 0 : 3;
  }
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  SC_HANDLE service = scm ? OpenServiceW(scm, kService, SERVICE_QUERY_STATUS) : nullptr;
  SERVICE_STATUS_PROCESS status{}; DWORD needed = 0;
  const bool ready = service && QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, reinterpret_cast<BYTE*>(&status), sizeof(status), &needed) && status.dwCurrentState == SERVICE_RUNNING;
  const bool installed = service != nullptr;
  if (service) CloseServiceHandle(service); if (scm) CloseServiceHandle(scm);
  if (action == L"status") return ready ? 0 : (installed ? 4 : 3);
  if (action != L"run" || argc != 3 || !ready) return 3;
  if (!WaitNamedPipeW(kPipe, 5000)) return 3;
  HANDLE pipe = CreateFileW(kPipe, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) return 3;
  ULONG server_pid = 0;
  // Refuse a squatted pipe before transmitting subscription credentials.
  if (!GetNamedPipeServerProcessId(pipe, &server_pid) || server_pid != status.dwProcessId) { CloseHandle(pipe); return 3; }
  std::ifstream file(std::filesystem::path(argv[2]), std::ios::binary);
  std::string config((std::istreambuf_iterator<char>(file)), {});
  DWORD size = static_cast<DWORD>(config.size()), ack = 0;
  bool ok = size > 0 && size <= 4 * 1024 * 1024 && Transfer(pipe, &size, sizeof(size), true) &&
    Transfer(pipe, config.data(), size, true) && Transfer(pipe, &ack, sizeof(ack), false) && ack == 1;
  if (ok) { char ended = 0; DWORD count = 0; ReadFile(pipe, &ended, 1, &count, nullptr); }
  CloseHandle(pipe); return ok ? 0 : 3;
}

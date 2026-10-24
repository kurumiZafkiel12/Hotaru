#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <string>
#include <sddl.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::UpdateTray(bool running) {
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateCompatibleBitmap(screen, 32, 32);
  const auto old = SelectObject(dc, bitmap);
  RECT rect{0, 0, 32, 32};
  FillRect(dc, &rect, reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
  HBRUSH brush = CreateSolidBrush(running ? RGB(164, 220, 115) : RGB(135, 145, 150));
  const auto old_brush = SelectObject(dc, brush);
  Ellipse(dc, 5, 5, 27, 27);
  SelectObject(dc, old_brush);
  HBITMAP mask = CreateBitmap(32, 32, 1, 1, nullptr);
  ICONINFO info{TRUE, 0, 0, mask, bitmap};
  HICON icon = CreateIconIndirect(&info);
  SelectObject(dc, old);
  DeleteObject(brush); DeleteObject(mask); DeleteObject(bitmap);
  DeleteDC(dc); ReleaseDC(nullptr, screen);
  tray_.hIcon = icon;
  wcscpy_s(tray_.szTip, running ? L"Hotaru · 代理运行中" : L"Hotaru · 代理已停止");
  Shell_NotifyIconW(NIM_MODIFY, &tray_);
  if (tray_icon_) DestroyIcon(tray_icon_);
  tray_icon_ = icon;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    flutter_controller_->engine()->messenger(), "hotaru/desktop",
    &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "status") {
      const auto value = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      UpdateTray(value && *value); result->Success();
    } else if (call.method_name() == "exit") {
      allow_exit_ = true; result->Success(); PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
    } else if (call.method_name() == "installService" || call.method_name() == "removeService") {
      HANDLE token = nullptr; DWORD needed = 0;
      std::wstring sid;
      if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        GetTokenInformation(token, TokenUser, nullptr, 0, &needed);
        std::vector<BYTE> data(needed);
        if (GetTokenInformation(token, TokenUser, data.data(), needed, &needed)) {
          LPWSTR value = nullptr;
          if (ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &value)) { sid = value; LocalFree(value); }
        }
        CloseHandle(token);
      }
      wchar_t path[32768]{}; GetModuleFileNameW(nullptr, path, 32768);
      const auto executable = std::wstring(path).substr(0, std::wstring(path).find_last_of(L"\\/")) + L"\\Hotaru.Service.exe";
      const std::wstring args = call.method_name() == "installService" ? L"install " + sid : L"remove";
      SHELLEXECUTEINFOW operation{}; operation.cbSize = sizeof(operation);
      operation.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
      operation.hwnd = GetHandle(); operation.lpVerb = L"runas"; operation.lpFile = executable.c_str(); operation.lpParameters = args.c_str(); operation.nShow = SW_HIDE;
      if (sid.empty() || !ShellExecuteExW(&operation)) { result->Error("SERVICE_INSTALL", "服务操作被取消或无法启动"); return; }
      DWORD exit_code = 3;
      if (WaitForSingleObject(operation.hProcess, 30000) == WAIT_OBJECT_0) GetExitCodeProcess(operation.hProcess, &exit_code);
      CloseHandle(operation.hProcess);
      if (exit_code == 0) result->Success(); else result->Error("SERVICE_INSTALL", "服务操作失败，请检查管理员权限及已有服务");
    } else { result->NotImplemented(); }
  });
  tray_.cbSize = sizeof(tray_); tray_.hWnd = GetHandle(); tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_.uCallbackMessage = WM_APP + 1;
  Shell_NotifyIconW(NIM_ADD, &tray_);
  UpdateTray(false);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (std::wstring(GetCommandLineW()).find(L"--silent") == std::wstring::npos) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  Shell_NotifyIconW(NIM_DELETE, &tray_);
  if (tray_icon_) { DestroyIcon(tray_icon_); tray_icon_ = nullptr; }
  channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE && !allow_exit_) { ShowWindow(hwnd, SW_HIDE); return 0; }
  if (message == RegisterWindowMessageW(L"TaskbarCreated")) {
    Shell_NotifyIconW(NIM_ADD, &tray_); return 0;
  }
  if (message == WM_APP + 1) {
    if (lparam == WM_LBUTTONDBLCLK) { ShowWindow(hwnd, SW_SHOW); SetForegroundWindow(hwnd); }
    if (lparam == WM_RBUTTONUP) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"显示 Hotaru");
      AppendMenuW(menu, MF_STRING, 2, L"退出并恢复系统代理");
      POINT point; GetCursorPos(&point); SetForegroundWindow(hwnd);
      const auto command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      if (command == 1) { ShowWindow(hwnd, SW_SHOW); SetForegroundWindow(hwnd); }
      if (command == 2 && channel_) channel_->InvokeMethod("exitRequested", nullptr);
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

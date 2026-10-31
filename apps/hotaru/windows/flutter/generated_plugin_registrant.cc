//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <app_links/app_links_plugin_c_api.h>
#include <connectivity_plus/connectivity_plus_windows_plugin.h>
#include <file_selector_windows/file_selector_windows.h>
#include <flutter_inappwebview_windows/flutter_inappwebview_windows_plugin_c_api.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>
#include <proxy/proxy_plugin_c_api.h>
#include <screen_retriever_windows/screen_retriever_windows_plugin_c_api.h>
#include <tray/tray_plugin_c_api.h>
#include <url_launcher_windows/url_launcher_windows.h>
#include <wifi_ssid/wifi_ssid_plugin_c_api.h>
#include <window/window_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  AppLinksPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AppLinksPluginCApi"));
  ConnectivityPlusWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ConnectivityPlusWindowsPlugin"));
  FileSelectorWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FileSelectorWindows"));
  FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterInappwebviewWindowsPluginCApi"));
  FlutterWebRTCPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterWebRTCPlugin"));
  ProxyPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ProxyPluginCApi"));
  ScreenRetrieverWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ScreenRetrieverWindowsPluginCApi"));
  TrayPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("TrayPluginCApi"));
  UrlLauncherWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UrlLauncherWindows"));
  WifiSsidPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WifiSsidPluginCApi"));
  WindowPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WindowPluginCApi"));
}

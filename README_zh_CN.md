<div align="center">

<img src="assets/images/icon.png" alt="Hotaru" width="88">

# Hotaru

基于 ClashMeta 的多平台代理客户端，简单易用，开源无广告。

[English](README.md) · **简体中文**

[![Release](https://img.shields.io/github/v/release/kurumiZafkiel12/Hotaru?style=flat-square&label=release)](https://github.com/kurumiZafkiel12/Hotaru/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kurumiZafkiel12/Hotaru/total?style=flat-square&logo=github)](https://github.com/kurumiZafkiel12/Hotaru/releases)
[![License](https://img.shields.io/github/license/kurumiZafkiel12/Hotaru?style=flat-square)](LICENSE)

[官网](https://kurumiZafkiel12.github.io/Hotaru/zh) · [下载](#下载) · [更新日志](CHANGELOG.md) · [从源码构建](#从源码构建)

</div>

> 本项目 fork 自 [FlClash](https://github.com/chen08209/FlClash) 0.9.2（提交 `7fd417f`），在相同 GPL-3.0 协议下独立改品牌、继续开发。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="snapshots/preview-dark.png">
    <img alt="Hotaru 在 MacBook 与手机上的仪表盘" src="snapshots/preview.png" width="92%">
  </picture>
</p>

## 功能

- **一个应用覆盖 Android、Windows、macOS 和 Linux**，桌面端同时提供 x64 与 ARM64 版本。
- **mihomo（Clash.Meta）内核**：规则分流、代理组、延迟测试、系统代理与 TUN 模式。
- **配置管理**：通过订阅链接或文件导入配置，内置编辑器，支持覆写脚本以及自定义规则、代理和代理组。
- **实时查看**连接、请求、DNS 查询和日志。
- **Hotaru 设计，融合 Apple 式交互**：固定萤火配色、浅色与深色主题，连续曲率圆角，弹出面板可在几档高度间吸附，布局随屏幕从手机到桌面自适应。
- **备份与恢复**：通过 WebDAV 或本地文件。
- **平台细节**：Android 上有快捷设置磁贴、分应用代理和 Android TV 支持；桌面端有托盘菜单和全局快捷键。
- **开源无广告**，以 GPL-3.0 协议发布。

## 0.5.0 Windows 交付

本轮由 Codex 接续 Muse 的 FlClash 基线，增加 Bettbox 扩展服务检测、网络诊断、0.4 旧配置导出路径与独立 Windows 代理守护。当前只发布 Windows x64；上文跨平台功能是源码继承，不代表本轮全部安装包已发布。

[升级与限制](docs/RELEASE-0.5.0.md) · [双上游功能合并台账](docs/FEATURE-MATRIX-0.5.0.md) · [来源与许可证](THIRD-PARTY.md)。0.4.x 旧数据保留，配置需要通过工具页导出后导入，不能直接复用旧数据库。两上游功能并集仍在继续完成，未移植项已逐条登记。

## 下载

从 [GitHub Releases](https://github.com/kurumiZafkiel12/Hotaru/releases/latest) 获取最新版本，或打开
[官网](https://kurumiZafkiel12.github.io/Hotaru/zh#download)，它会自动为你的设备选好安装包。

| 平台 | 安装包 | 说明 |
| --- | --- | --- |
| Android | `arm64-v8a`、`armeabi-v7a`、`x86_64` 三种 APK | 绝大多数手机选 `arm64-v8a`。 |
| Windows 10 及以上 | 安装版（`.exe`）或便携版（`.zip`），分 x64 与 ARM64 | 骁龙等 ARM 架构笔记本选 ARM64。 |
| macOS 12 及以上 | Apple Silicon 与 Intel 两种 DMG | |
| Linux | `.deb`、`.rpm` 和 AppImage，分 x64 与 ARM64 | 托盘依赖见下方说明。 |

<p>
  <a href="https://github.com/kurumiZafkiel12/Hotaru/releases/latest"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" height="56"></a>
</p>

**Linux 托盘图标**

`.deb` 安装包会自动安装所需依赖。使用 AppImage 或 `.rpm` 时，需要先安装 AyatanaAppIndicator 库，托盘图标才能显示：

```bash
sudo apt-get install libayatana-appindicator3-1   # Debian 与 Ubuntu
sudo dnf install libayatana-appindicator-gtk3     # Fedora
```

**无人值守的桌面环境**

Hotaru 要在免责声明被接受后才会启动核心。在容器等无人点击的环境里，可在应用的环境变量中设置
`HOTARU_ACCEPT_DISCLAIMER=1`，首次启动时即视为接受。

## 使用

**通过链接导入配置。** 打开下面格式的链接，即可把订阅导入 Hotaru。`clashmeta://` 和 `hotaru://` 开头的链接同样可用。

```text
clash://install-config?url=<经过 URL 编码的订阅链接>
```

**Android 自动化。** Tasker、MacroDroid 等应用可以用下面的 Action 启动 Activity，从而启动、停止或切换代理：

```text
dev.hotaru.hotaru.action.START
dev.hotaru.hotaru.action.STOP
dev.hotaru.hotaru.action.TOGGLE
```

在电脑上也可以通过 adb 触发：

```bash
adb shell am start -a dev.hotaru.hotaru.action.TOGGLE
```

## 从源码构建

需要 [Flutter](https://docs.flutter.dev/get-started/install) 3.47（正式版构建使用 3.47.6）、[Go](https://go.dev/dl/) 1.27，
以及通过 rustup 安装的 [Rust](https://rustup.rs/)。桌面端需要在对应系统上构建，Android 在任意系统上都能构建。

```bash
git clone --recursive https://github.com/kurumiZafkiel12/Hotaru.git
cd Hotaru
flutter pub get
dart setup.dart android   # 或 windows、macos、linux
```

安装包输出到 `dist/`。Go 内核和 Rust 库会在 Flutter 构建过程中一并编译。

| 平台 | 额外依赖 |
| --- | --- |
| Android | 带 NDK 的 Android SDK。加上 `--arch arm64` 可以只构建单个 ABI。 |
| Windows | 编译内核用的 GCC（MinGW-w64），以及打包安装程序用的 [Inno Setup](https://jrsoftware.org/isinfo.php) 6。 |
| macOS | Xcode 与 Node.js。脚本会通过 npm 安装 `appdmg`。 |
| Linux | Debian 或 Ubuntu。脚本会用 apt 安装构建所需的软件包，并下载 `appimagetool`。 |

其余选项可以运行 `dart setup.dart --help` 查看，例如用 `--targets` 只构建部分安装包格式。

## 支持

给仓库点一个 Star 是支持项目最简单的方式。问题、Bug 与功能建议请提交到 [GitHub Issues](https://github.com/kurumiZafkiel12/Hotaru/issues)。

<a href="https://star-history.com/#kurumiZafkiel12/Hotaru&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=kurumiZafkiel12/Hotaru&type=Date&theme=dark">
    <img alt="Star history" src="https://api.star-history.com/svg?repos=kurumiZafkiel12/Hotaru&type=Date" width="640">
  </picture>
</a>

## 许可证

Hotaru 以 [GPL-3.0 协议](LICENSE)发布。

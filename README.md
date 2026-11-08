<div align="center">
<img src="apps/hotaru/assets/images/icon.png" alt="Hotaru 蛍" width="88">

# Hotaru · 蛍

简洁、开源的跨平台代理客户端，支持 Windows 与 Android。

[**下载安装**](https://github.com/kurumiZafkiel12/Hotaru/releases/latest) · [更新记录](https://github.com/kurumiZafkiel12/Hotaru/releases) · [问题反馈](https://github.com/kurumiZafkiel12/Hotaru/issues) · [交流群](https://t.me/kurumizafkiel1) · [English](docs/README_en.md)
</div>

## 功能

- **仪表盘**：查看出口 IP、运行状态与实时流量，按需添加和排列组件。
- **配置与分流**：导入订阅或配置文件，管理节点、代理组、规则与覆写。
- **网络接管**：Windows 系统代理与 TUN，Android VPN，支持规则／全局／直连模式。
- **网络工具**：带宽测速、50+ 服务连通与分流检查、应用内 DNS／WebRTC 检测与 IP 检测站。
- **运行管理**：查看连接链路、应用流量排行与日志，本地或 WebDAV 备份配置。

Hotaru 不提供代理服务器或订阅服务，使用前需要导入自己的配置。服务连通不等于账号或内容解锁；网页检测结果反映本次应用内测量，不代表所有应用或浏览器都无泄漏。

## 下载与安装

| 平台 | 版本要求 | 下载 |
| --- | --- | --- |
| Windows | Windows 10/11，x64 | [安装版与便携版](https://github.com/kurumiZafkiel12/Hotaru/releases/latest) |
| Android | Android 7.0 及以上 | [ARM64／ARMv7／x86_64 APK](https://github.com/kurumiZafkiel12/Hotaru/releases/tag/v0.0.5) |

安装文件及 SHA256 校验清单均在发布页。当前未提供 macOS 和 Linux 安装包。

- **Windows**：在托盘完全退出 Hotaru 后覆盖安装；便携版解压到新目录使用。安装程序尚未进行 Authenticode 签名。
- **Android**：大多数手机选择 ARM64。正式包采用固定签名，可覆盖更新；早期 `.dev` 调试包请先导出配置再迁移到正式包。
- **开始使用**：在「订阅」导入订阅或文件，在「节点选择」选择节点，再按需开启网络接管。
- **升级前**：建议导出配置备份。Windows 0.0.7 更换内核后需手动重新导入配置；原文件与偏好保留。不兼容项会在导入时列出。已有仪表盘布局可通过「编辑 → 恢复默认 → 完成」重置。

当前版本及历史变化见[发布说明](https://github.com/kurumiZafkiel12/Hotaru/releases)。

<details>
<summary>从源码构建</summary>

需要 Flutter 3.47.6、Go 1.27.1 和 Rust；Windows 构建还需要 Visual Studio C++ 桌面组件和 Inno Setup 6。

```bash
git clone --recursive https://github.com/kurumiZafkiel12/Hotaru.git
cd Hotaru/apps/hotaru
flutter pub get
dart setup.dart windows --env stable
```

完整命令见 [.agents/commands.md](.agents/commands.md)，可选编辑器配置见 [编辑器配置](apps/hotaru/tool/editor-config/README.md)。

</details>

## 开源与致谢

Hotaru 基于 [FlClash](https://github.com/chen08209/FlClash)，Windows 使用 [Hotaru-Core](https://github.com/kurumiZafkiel12/Hotaru-Core)（基于 [sing-box](https://github.com/SagerNet/sing-box)），现有 Android 版使用 [Mihomo](https://github.com/MetaCubeX/mihomo)，并参考 [Bettbox](https://github.com/appshubcc/Bettbox) 的部分工具体验。以 [GPL-3.0](LICENSE) 发布，保留上游及相关依赖的许可证和作者署名。

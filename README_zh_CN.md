<div align="center">
<img src="assets/images/icon.png" alt="Hotaru 蛍" width="88">

# Hotaru · 蛍

简洁、开源的 Mihomo 代理客户端。先把 Windows 做好，再逐步完善其他平台。

[![版本](https://img.shields.io/badge/release-v0.0.2-67b7d1)](https://github.com/kurumiZafkiel12/Hotaru/releases/tag/v0.0.2)
[![安装包](https://img.shields.io/badge/Windows-下载安装包-2d7d9a?logo=windows)](https://github.com/kurumiZafkiel12/Hotaru/releases/download/v0.0.2/Hotaru-0.0.2-windows-amd64-setup.exe)
[![便携版](https://img.shields.io/badge/Windows-下载便携版-67b7d1?logo=windows)](https://github.com/kurumiZafkiel12/Hotaru/releases/download/v0.0.2/Hotaru-0.0.2-windows-amd64.zip)

[发布说明](https://github.com/kurumiZafkiel12/Hotaru/releases/tag/v0.0.2) · [问题反馈](https://github.com/kurumiZafkiel12/Hotaru/issues) · [作者交流群](https://t.me/kurumizafkiel1) · [English](README_en.md)
</div>

## 项目介绍

Hotaru（蛍）基于 [FlClash 0.9.2](https://github.com/chen08209/FlClash/tree/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7) 移植，使用 [Mihomo](https://github.com/MetaCubeX/mihomo) 内核，独立维护产品界面、默认设置和工具箱。功能演进同时参考 Bettbox，重复功能合并成一个入口。项目不提供代理服务器或订阅服务，需要导入你自己的节点或配置。

当前正式提供 **Windows 10/11 x64** 安装包和便携包。源码保留上游跨平台结构；Android、Linux、macOS 尚未作为本版本的安装包交付，不代表已经完成实机验收。

## 已有功能

- 配置管理：订阅链接、配置文件导入、自动更新、多配置切换、编辑与覆写。
- 节点与分流：节点列表、延迟测试、切换、代理组，以及规则／全局／直连模式；默认沿用订阅的分流规则。
- Windows 接管：系统代理、TUN、服务承载、托盘和启动设置。
- 运行状态：实时连接、流量、DNS 与日志。
- 工具箱：节点带宽测速、IP 质量及网络检查；外部检测结果取决于相应服务。
- 备份：本地导入导出与 WebDAV。

## v0.0.2 更新

- 采用「萤火桌面」：更窄的品牌侧栏、出口主卡片、小组件分区与深浅色绿色配色。
- 保留 IP 质量检测、详情、重新检测，以及网络速度、配置用量、内网 IP、服务检测、内存、连接与策略组等原有组件；不重置已有订阅、规则、覆写或小组件设置。
- 出口地区改用内置国旗字体，保留未知地区回退和刷新状态。
- 诊断日志改为追加写与有界轮转，尾部解析移到独立 isolate；修正用户选择卸载清理时的数据目录。
- 修正 Windows 失去激活或最小化时仍把焦点设回自身的问题；窗口闪动仍待用户实机复测。
- 随机 UI 卡死仍未捕获根因，本版不宣称已经解决。覆盖安装也暂不承诺零残留。

## v0.0.1 更新

按维护者要求，产品版本从 0.5.x 重新编号为 0.0.1；继续维护现有 FlClash 移植代码。

- 修正默认覆写缺失造成的测量口径差异：统一延迟和 TCP 并发默认开启并实际生效。
- 默认加入 IPv6（关闭）及 Geo 低内存模式（开启）；测速链接不强制覆写。
- 首次升级补齐四个覆写项，保留已有开关值、节点和规则；之后仍可自行修改或移除。
- 延迟结果提供脱敏错误类别、实测耗时及有效统一延迟状态。本地诊断需主动开启，不自动上传。
- 首次启动直接进入软件，移除强制免责声明、已读确认和复述流程。
- 清理免责声明入口，修正作者交流群链接，保留许可证与上游致谢。

同一节点在统一延迟关闭和开启时，测量可能包含不同的建连开销。已通过隔离实测复现差异，用户也已确认开启有效覆写后恢复正常；软件不会将数值固定除以某个倍数。节点不可达时仍会如实显示失败或超时。

## 安装与更新

1. 下载上方安装包（推荐）或便携包，并核对发布页的 SHA256SUMS。
2. 从托盘完全退出正在运行的 Hotaru，再覆盖安装。便携版请解压整个压缩包后运行。
3. 在「配置」导入订阅或配置，在「代理」查看与选择节点，再按需开启系统代理或 TUN。

v0.0.1 可正常检查到本版；仍使用 0.5.x 的用户需手动下载安装，旧版版本号比较不会发现编号较小的更新。现有配置通常位于 `%APPDATA%\dev.hotaru\Hotaru`，升级前可在工具页备份；不要删除目录来升级。首次启用 TUN 可能需要服务安装授权。安装包尚未数字签名。

## 从源码构建

正式构建使用 Flutter 3.47.6、Go 1.27.1、Rust；Windows 还需要 Visual Studio C++ 桌面组件和 Inno Setup 6。

```bash
git clone --recursive https://github.com/kurumiZafkiel12/Hotaru.git
cd Hotaru
flutter pub get
dart setup.dart windows --env stable
```

源代码与测试随仓库提供。发布包由 GitHub Actions 构建；详细步骤见 [AGENTS.md](AGENTS.md) 和 [.agents/commands.md](.agents/commands.md)。

## 开源与致谢

以 [GPL-3.0](LICENSE) 发布，修改和再分发请遵守许可证。感谢 [FlClash](https://github.com/chen08209/FlClash) 及其贡献者、[Mihomo](https://github.com/MetaCubeX/mihomo)、[Bettbox](https://github.com/appshubcc/Bettbox) 和相关依赖。内核沿用 FlClash 维护的 Mihomo 分支；图标与其他上游素材的原作者署名保留于源码及应用关于页。Hotaru 是独立派生项目。

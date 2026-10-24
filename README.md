# Hotaru · 蛍

Windows 优先的开源 Mihomo 客户端，简洁小组件首页与独立工具箱，后续支持 Android / Linux。采用 GPL-3.0-or-later。

从 [GitHub Releases](https://github.com/kurumiZafkiel12/Hotaru/releases) 下载 `Hotaru-0.4.1-windows-x64-setup.exe`，关闭旧版后覆盖安装。包含已校验的 Mihomo v1.19.33 与 Node.js Script 运行时，不需要开发环境。安装包尚未签名。

使用：**配置页导入 → 节点页启动 → 按需开启系统代理**。默认保留订阅规则，节点页显示策略组与 Provider 节点。关窗隐藏到托盘；右键托盘“退出并恢复系统代理”才会退出。可选服务首次安装需要管理员授权，日常使用无需重复 UAC；TUN 下一阶段开放。

0.4.1 提供订阅定时更新/用量、TCP/真连接批量测速、三态分流、远程节点集与规则集、Merge+Script 覆写、连接/日志/流量、崩溃代理守护、托盘/静默自启、自动检查与校验安装更新。功能边界、升级步骤和限制见 [0.4.1 发布说明](docs/RELEASE-0.4.1.md)，参考实现分析见 [源码对照](docs/REFERENCE-ANALYSIS-0.4.1.md)。

本地配置包含节点凭据，保存在 `%APPDATA%/Hotaru`，不会上传；卸载保留。原有 v0.3 与历史交还报告保留用于追溯。

## 开发检查

```sh
cd apps/hotaru
flutter pub get
dart format lib test tool
flutter analyze
flutter test
flutter build windows --release
```

真实内核本地链路：dart run tool/proxy_loop_smoke.dart <mihomo绝对路径>。Windows CI 还会构建安装包、静默安装、覆盖安装和卸载，检查用户布局保留。

## 许可与来源

Hotaru 自本轮起采用 GPL-3.0-or-later；见 LICENSE。内核与其他组件许可证/源代码见 THIRD-PARTY.md。Windows 发布同时提供固定版本内核源码归档。Flutter 及依赖许可保留在应用许可页和数据目录。

参考 FlClash、Bettbox、Clash Verge Rev 的产品体验，Mihomo 为实际代理内核。

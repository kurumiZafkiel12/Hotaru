# Hotaru · 蛍

Windows 优先的 Mihomo 代理客户端。原生 Flutter 工程位于 apps/hotaru，网页原型 src/ 仅作为早期交互参考。

## v0.4 安装版

从 [Releases](https://github.com/kurumiZafkiel12/Hotaru/releases) 下载 Hotaru-0.4.0-windows-x64-setup.exe。安装到当前用户目录，包含校验过的 Mihomo v1.19.33，无需管理员权限或开发环境。安装包由 CI 在测试与验证通过后发布。

启动 → 节点页导入订阅/链接 → 选择节点 → 启动代理 → 按需打开系统代理。切换首页/工具箱仍保持运行。正常关闭应用会停止代理并恢复它管理的系统代理；强制退出后可在下次启动用恢复按钮处理。

更新方式：点击“下载更新”，下载新安装包，关闭 Hotaru 后覆盖安装。订阅和布局保留。当前没有后台自动更新。旧 v0.3 ZIP 可以保留；使用安装版前关闭旧版本，避免争用系统代理。

## 已实现

- 可编辑小组件首页、工具箱入口、节点与订阅保存。
- Mihomo YAML/JSON（显式 proxies）、Base64 订阅、SOCKS5、HTTP(S)、SS、VMess、VLESS、Trojan、Hysteria2，支持范围由解析器校验。
- 节点选择、混合入口、真实内核延迟、节点切换、Windows 系统代理备份/恢复与即时通知。
- 内置内核路径、正常退出清理、内核失败恢复、单实例、Windows Job Object 子进程回收。
- Inno Setup 安装/覆盖升级/卸载流程；许可页及发布校验和。

完整配置会覆写入站与控制接口字段，确保仅使用本应用控制的回环端口；TUN 和外部面板关闭。跨订阅切换与导入前需要停止运行中的代理。

## 待完成与限制

TUN、多跳、可视化规则编辑、下载测速、IP 质量数据源、托盘、开机启动、Android/Linux 实机适配。首页流量/IP 仍为明确占位。节点凭据保存在 %APPDATA%/Hotaru 的明文 JSON；卸载保留此目录。真实订阅和公网节点需用户验收。

Windows 包尚未签名；对安装、更新和测试的具体证据见 [验收记录](docs/V04-VERIFICATION.md)。历史 [Muse v0.3 交还报告](docs/HANDOFF-REPORT.md) 保留原文，不作为当前版本说明。

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

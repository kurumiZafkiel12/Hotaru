# Hotaru · 蛍

一点微光，自在连接。

独立开发中的 Mihomo 客户端：小组件首页、网络工具箱与多跳代理。Windows 10/11 x64 优先，后续 Android、Linux。唯一内核为 Mihomo。

**当前状态（2026-10-24）：v0.3 已实现最小可用代理闭环（导入→保存→选节点→启动→真实流量→切换/测速→停止），已在本机用真实 Mihomo v1.19.33 做本地端到端验证（SOCKS5 节点链路证据见交接报告）。已发布预览仍为 preview-3（界面版）；v0.3 尚未推送发布。仍未签名、不含 Mihomo 本体（需自备），系统代理为 Windows 实现待实机验收，TUN 未实现。**

## 下载（Windows 界面预览）

[preview-3 预发布](https://github.com/kurumiZafkiel12/Hotaru/releases/tag/preview-3) · [直接下载 ZIP](https://github.com/kurumiZafkiel12/Hotaru/releases/download/preview-3/Hotaru-windows-x64-preview.zip)
SHA256：`aa6c20f91366b3940e01a14314322393deaffed7ea0bff3aed0bf415ca92cdde`

下载后完整解压再运行 `hotaru.exe`，不要单独移动 EXE。main 分支的 Windows 工作流在检查与构建通过后会自动发布带 SHA256 的新预发布，版本号以 Releases 为准。

## 已实现（原生工程 apps/hotaru）

- 小组件首页：添加、移除、拖动排序、恢复默认；布局只存组件编号（`%APPDATA%/Hotaru/layout-v1.json`），采用临时文件 + 重命名原子保存，损坏时回退默认并提示。
- 工具箱页（功能占位，明确标注开发中，不生成模拟测速/IP 数据）与导入预览入口。
- 内核诊断页：对用户自备的本机 Mihomo 做配置校验、子进程启动、随机密钥回环认证健康检查与停止；离开页面即停止该页内核；控制端口每次启动选取空闲端口。诊断模式不开放代理入口，不改系统代理。
- 订阅与节点（「节点」页）：显式 `proxies` 的 Mihomo YAML/JSON、Base64 订阅、带超时与 2 MiB 上限的 HTTPS 订阅下载；URI 支持 SOCKS5、HTTP(S)、Trojan（含 ws/grpc、allowInsecure）、SS（SIP002/旧式/插件）、VMess、VLESS（含 Reality）、Hysteria2，未知参数明确拒绝不静默丢弃；“仅提取节点 / 完整配置”双模式。导入成功即原子保存到本机（`%APPDATA%/Hotaru/profiles-v1.json`，含节点凭据，仅存用户目录、不进日志），失败不影响已有订阅。
- 代理闭环：选节点 → 生成运行配置（自动选择 url-test 组 + 手动选择组；完整配置保留其自身策略组/规则）→ Mihomo 校验 → 启动本地混合端口（默认 7890，被占用自动换空闲端口并告知）→ 运行中免重启切换节点（经内核 API）→ 内核实测延迟 → 停止。流量经内核 `/connections` 可见完整链路。
- 系统代理（Windows）：开关在「节点」页；开启前备份原注册表设置到本机文件，关闭时原样恢复；异常退出遗留备份时下次启动可一键恢复。（Windows 实机待验收。）

## 尚未实现

TUN、域名/IP/应用级分流规则编辑器、下载测速、故障切换策略组、多跳代理、连接记录页、流量统计、托盘、开机启动；provider-only 订阅配置；工具箱的 IP 质量检测未接入数据源，查不到的数据不会编造。系统代理的 WinINet 即时刷新与 Windows 实机行为待验收。

## 网页原型（仓库根目录 src/）

早期 Vite 布局参考，含组件编辑与多跳草稿校验，仅用于交互参考，不是桌面产品。正式开发只改 `apps/hotaru`。

```sh
npm ci
npm run check
npx playwright install chromium
npx playwright test
```

## 原生自检

```sh
cd apps/hotaru
flutter pub get
dart format lib test tool
flutter analyze
flutter test
flutter build windows --release   # 需 Windows C++ 工具链，或由 CI 执行
```

详细步骤和验收标准：[开发计划](docs/PLAN.md) · [架构边界](docs/ARCHITECTURE.md) · [M1 验证记录](docs/M1-VERIFICATION.md) · [导入范围](docs/M2-IMPORT.md) · [最新交接报告](docs/HANDOFF-REPORT.md)。

## 参考与许可

内核：[Mihomo](https://github.com/MetaCubeX/mihomo)（目前未随包分发）。体验参考：[FlClash](https://github.com/chen08209/FlClash)、[Bettbox](https://github.com/appshubcc/Bettbox)、[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)，未复制其客户端代码。

目前为公开开发仓库；**正式开源许可证尚未确定，公开仓库不等于已授予开源许可**。引入/分发 Mihomo 前将确认其许可证与第三方声明义务。依赖保留各自许可。

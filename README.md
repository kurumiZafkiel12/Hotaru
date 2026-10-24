# Hotaru · 蛍

一点微光，自在连接。

独立开发中的 Mihomo 客户端：小组件首页、网络工具箱与多跳代理。Windows 10/11 x64 优先，后续 Android、Linux。

**当前是网页交互原型，不是可用代理软件，没有 Windows EXE 或安装包。**

## 已实现
- 深色萤光主题、响应式首页和工具箱。
- 组件添加、移除、拖动和按钮排序、恢复默认、持久化布局。
- 多跳路径草稿与重复节点检查（不是协议或连通性验证）。
- 模型测试、浏览器交互测试、CI 构建。

## 后续功能
订阅与单节点导入；提取节点/完整配置双模式；系统代理、TUN；域名/IP/应用分流；测速、自动选择、故障切换；多跳代理；免费来源 IP 检测；连接记录、统计、托盘、开机启动。

详细步骤和验收标准：[开发计划](docs/PLAN.md) · [架构边界](docs/ARCHITECTURE.md)。

## 运行原型
需要 Node.js 22.12+，CI 使用 24。

```sh
npm ci
npm run dev
```

访问终端显示的本地地址。原型仅保存组件布局，不读取节点凭据、不修改系统代理、不发起网络检测。未接入功能明确禁用，不使用模拟连接或测速结果。

## 自检
```sh
npm run check
npx playwright install chromium
npx playwright test
```

构建输出在 dist/。浏览器测试覆盖组件保存、排序、工具箱禁用、多跳校验与窄屏溢出。

## 下载
Actions 产物是网页原型，**不是 Windows 安装包**。正式应用通过实机验收后发布到 [Releases](https://github.com/kurumiZafkiel12/Hotaru/releases)。

## 参考与许可
[Mihomo](https://github.com/MetaCubeX/mihomo) 为计划使用的内核，目前未分发；[FlClash](https://github.com/chen08209/FlClash)、[Bettbox](https://github.com/appshubcc/Bettbox)、[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) 为体验参考，未复制其客户端代码。

目前为公开开发仓库；正式开源许可证将在引入内核与发布应用前确定。依赖保留各自许可。

## 正式工程进度（M1）
apps/hotaru/ 已建立 Flutter Windows、Android、Linux 工程；当前界面为内核诊断页，小组件界面尚未迁移。桌面适配层可校验配置、启动 Mihomo、认证健康检查和停止。诊断模式不启用代理入口或 TUN。

本机 5 项 Flutter 测试及真实 Mihomo 启停检查通过；Windows 原生编译等待 CI 验证。详情见 [M1 验证记录](docs/M1-VERIFICATION.md)。尚无可用代理安装包。

## 导入预览（M2a）
原生诊断页新增“导入预览”：支持显式 proxies 的 Mihomo YAML/JSON、SOCKS5/HTTP(S)/基础 Trojan URI，以及有超时和大小限制的 HTTPS 订阅下载。提供节点提取和完整配置两种结构检查模式。结果尚不保存、不应用；完整订阅管理与其他协议仍在开发。见 [导入范围与验收](docs/M2-IMPORT.md)。

## Windows 界面预览
原生首页已加入可添加、移除、拖动排序并保存的小组件，以及工具箱、导入预览入口。main 分支的 Windows 工作流在检查和构建通过后自动发布带 SHA256 的预发布 ZIP，见 [Releases](https://github.com/kurumiZafkiel12/Hotaru/releases)。下载后完整解压，运行 hotaru.exe，不要单独移动 EXE。这是未签名界面预览，不是可用代理客户端；不含 Mihomo，未启用系统代理或 TUN。原生诊断版此前已成功通过 Windows CI 编译，新界面的构建结果请以对应 Release 为准。

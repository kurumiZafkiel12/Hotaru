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

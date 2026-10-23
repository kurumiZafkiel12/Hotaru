# Hotaru · 蛍

简洁、可定制的 Mihomo 代理客户端，配备小组件首页与网络工具箱。

> 开发准备阶段：目前仓库只有项目说明，尚无应用源码、安装包或可运行版本。下列功能均为开发计划，不代表已实现。

## 产品方向

独立开发客户端，采用 Mihomo 单内核。首个平台为 Windows 10/11 x64，后续计划支持 Android、Linux。

- 简洁首页：可添加、移除、拖动排序的小组件。
- 订阅链接与单节点链接导入；提供仅导入节点和完整配置两种模式。
- 系统代理、TUN、域名/IP/应用分流。
- 节点延迟与下载测速、自动选择、故障切换。
- 可视化多跳代理链，显示入口、中转和出口。
- 网络工具箱：出口 IP、免费来源的 IP 质量检测与 DNS 诊断。
- 连接记录、流量统计、托盘和开机启动。
- 新手友好的默认设置，以及可展开的高级配置。

## 开发路线

- [x] 确定产品需求与品牌名称。
- [x] 创建公开 GitHub 仓库。
- [ ] 制作首页与工具箱交互原型。
- [ ] 建立工程、构建与自动测试流程。
- [ ] 接入 Mihomo，实现配置导入与连接。
- [ ] 实现 Windows 系统代理、TUN 与退出恢复。
- [ ] 实现分流、多跳及工具箱。
- [ ] 发布经过验证的 Windows 预览包。
- [ ] 适配 Android、Linux。

## 下载

目前没有可下载的 Windows 应用。首个可运行版本通过验证后，将发布到本仓库的 [Releases](https://github.com/kurumiZafkiel12/Hotaru/releases)。GitHub 的 Source code ZIP 是仓库源码，不是安装包。

## 参考与致谢

- [Mihomo](https://github.com/MetaCubeX/mihomo)：计划采用的代理内核。
- [FlClash](https://github.com/chen08209/FlClash)、[Bettbox](https://github.com/appshubcc/Bettbox)：产品体验参考。
- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)：链式代理交互参考。

本项目计划开源；具体许可证将在引入代码与依赖前确定，并保留相应第三方许可与声明。

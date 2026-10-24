# 0.4.1 源码对照与实现决定

整理：Codex，2026-10-24。阅读对应源码后独立实现，没有把其他客户端整体复制进 Hotaru。

## FlClash

审阅提交 `7fd417fb9a9a277c6a9339a8ac87f907df7c25f7`，重点阅读 [profile.dart](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/models/profile.dart)、[ProfilesAction](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/lib/providers/actions/profiles.dart)、`lib/views/profiles/extend/script.dart`、`lib/manager/tray_manager.dart`、`services/helper/src/main.rs`。

有价值的边界：订阅源、选中组节点、更新时间、流量信息和覆写分开保存；更新先验证临时文件；后台下载完成后重新取最新状态，避免覆盖期间的编辑。脚本由用户显式绑定。Hotaru 采用相同的数据责任划分，订阅更新期间禁用冲突编辑；先验证候选，再替换持久化源。服务与 UI 是两个真正的进程，而不是给普通子进程换名字。

## Bettbox

审阅提交 `1fb8806fdf8275a3694cda31eec7ed2062330aee`，重点阅读 [profile.dart](https://github.com/appshubcc/Bettbox/blob/1fb8806fdf8275a3694cda31eec7ed2062330aee/lib/models/profile.dart)、`lib/views/profiles/override_profile.dart`、`lib/manager/tray_manager.dart`。

关注 `subscription-userinfo` 的 upload/download/total/expire、临时文件验证与写入、选中节点映射，以及 Windows 托盘显示/菜单行为。Hotaru 的缺失值显示“来源未提供”，避免把缺失配额误显示为零流量或永久有效；关窗与退出拆开。保存失败不再删除旧文件后重试。

## Clash Verge Rev

审阅提交 `3d9a79a3fb4d324ac66033cd3e27413eb6331e66`，重点阅读 [profiles.rs](https://github.com/clash-verge-rev/clash-verge-rev/blob/3d9a79a3fb4d324ac66033cd3e27413eb6331e66/src-tauri/src/config/profiles.rs)、`src-tauri/src/core/service.rs`、`src-tauri/src/cmd/service.rs`。

关注配置写锁、独立 merge/script 关联、Provider 尚未就绪时的选择恢复、服务安装与健康状态、OwnerSession 和 sidecar 回退边界。Hotaru 不强制猜一个策略组来修改，运行时让用户显式选择组；刷新 Provider 后从 API 重新读取。服务安装失败不悄悄宣称“服务已运行”。第一阶段采用低权限 LocalService、固定内核、当前用户管道、连接租约；不允许调用方上传任意可执行路径或命令行。TUN 的高权限网络管理接口仍需另行实现，不能将安装 SCM 服务等同于完成 TUN。

## Mihomo 实测发现

以实际打包的 v1.19.33 为准，对照 [官方 API 文档](https://wiki.metacubex.one/api/) 与 [`hub/route/provider.go`](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/hub/route/provider.go)。`/proxies` 不是远程节点的完整来源；必须并入 `/providers/proxies` 的各集合。远程单节点测速使用 `/providers/proxies/{provider}/{node}/healthcheck`，直接访问 `/proxies/{node}/delay` 会漏掉 Provider 节点。普通节点仍使用后者。四组类型、切换、模式、Provider 更新、规则集、流量 WS 都由真实内核测试覆盖。

保留原始路由不是逐字执行整个远程配置：入站、external-controller、secret、TUN 由客户端最终固定；远程 Provider 缓存路径按 URL 哈希重写到内核工作目录，避免跨订阅路径冲突。

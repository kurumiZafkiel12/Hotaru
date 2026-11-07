sing-box 内核 beta（纯 sing-box 数据面）：界面与配置保持不变，内核只剩 sing-box。

### 更新内容

- 内核数据面为 sing-box 1.14.4（官方构建），且是唯一数据面：实际承载流量的连接、节点切换、延迟测试、流量统计与逐节点带宽测速均由 sing-box 完成，控制走其 clash_api。**没有 Mihomo 兜底**——sing-box 启动失败时连接会明确失败，原因写入核心日志，不会悄悄换回旧内核。
- 现有 Clash 订阅与配置可直接沿用：生效配置在应用时自动翻译为 sing-box 配置（支持 VLESS、VMess、Trojan、Hysteria2、AnyTLS、TUIC、Shadowsocks、SOCKS、HTTP 及 select / url-test 分组，含 Reality、uTLS、WS / gRPC / HTTPUpgrade 传输与 dialer-proxy 链式代理）；分组中的 DIRECT / REJECT 成员与自定义监听（含测速专用口）一并正确翻译。
- 翻译中无法等价转换的内容（load-balance / fallback 分组、fake-ip、个别规则类型等）会逐项写入核心日志，不静默丢弃。

### 已知限制（beta）

- 本版仅提供 Windows x64；Android 移植在后续版本。
- 连接列表页、模式切换（规则 / 全局 / 直连）的即时生效、按应用分流等仍走 Mihomo 侧语义，可能与 sing-box 实际路径不一致。
- GEOIP / GEOSITE 规则经远程规则集（SagerNet 官方 sing-geoip / sing-geosite）实现，首次启用 TUN 或切换配置时需联网下载。
- Hysteria2 / TUIC 等 UDP 协议的可用性以真实网络为准。

### 使用提示

- 本次提供 Windows x64 安装程序与便携包。安装程序未做 Authenticode 签名，可通过 SHA256SUMS 核对下载文件。
- 自行确认内核的方法：连接后任务管理器中会出现 sing-box.exe 进程；核心数据目录下有 singbox.json 与 singbox.log，核心日志含 [sing-box] 前缀行。

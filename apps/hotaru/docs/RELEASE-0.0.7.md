sing-box 内核 beta：数据面切换为 sing-box，界面与配置保持不变。

### 更新内容

- 内核数据面由 Mihomo 换为 sing-box 1.14.4（官方构建）：实际承载流量的连接、节点切换、延迟测试与流量统计均由 sing-box 完成，控制走其 clash_api。
- 现有 Clash 订阅与配置可直接沿用：生效配置在应用时自动翻译为 sing-box 配置（支持 VLESS、VMess、Trojan、Hysteria2、AnyTLS、TUIC、Shadowsocks、SOCKS、HTTP 及 select / url-test 分组，含 Reality、uTLS、WS / gRPC / HTTPUpgrade 传输与 dialer-proxy 链式代理）。
- 翻译中无法等价转换的内容（load-balance / fallback 分组、fake-ip、个别规则类型等）会逐项写入核心日志，不静默丢弃。
- sing-box 启动失败时自动回退到内置 Mihomo 数据面，应用仍可正常使用（失败原因见核心日志）。

### 已知限制（beta）

- 本版仅提供 Windows x64；Android 仍为 Mihomo 数据面，sing-box 移植在后续版本。
- 连接列表页、模式切换（规则 / 全局 / 直连）的即时生效、按应用分流等仍走 Mihomo 侧语义，可能与 sing-box 实际路径不一致。
- GEOIP / GEOSITE 规则经远程规则集（SagerNet 官方 sing-geoip / sing-geosite）实现，首次启用 TUN 或切换配置时需联网下载。
- Hysteria2 / TUIC 等 UDP 协议的可用性以真实网络为准。

### 使用提示

- 本次提供 Windows x64 安装程序与便携包。安装程序未做 Authenticode 签名，可通过 SHA256SUMS 核对下载文件。
- 如需关闭 sing-box 数据面：在核心数据目录放置空文件 `singbox-beta.off` 后重启应用即可整体回退。

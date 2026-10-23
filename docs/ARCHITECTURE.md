# 架构边界

当前 src/ 是无内核的网页交互原型。它不修改系统代理，不读取订阅，不自动访问检测服务。仅将组件 ID 顺序写入 localStorage。

正式应用拟采用 UI → 应用服务 → 领域模型 → CoreAdapter / PlatformAdapter / Storage 的结构。

CoreAdapter 管理 Mihomo 生命周期与控制 API；PlatformAdapter 管理系统代理、TUN、托盘和启动项；检测服务需明确绑定目标出站。两种订阅模式共享节点标识但保留各自配置语义。

连接生命周期：停止 → 校验配置 → 启动 → 健康检查 → 运行 → 停止/错误。未经健康检查不可显示已连接。系统设置恢复和进程结束属于独立可重试清理步骤。

正式技术栈将在 M1 构建验证后锁定。当前原型不宣称可直接打包为 Windows 或 Android 代理应用。

# Hotaru · 蛍（正式 Flutter 工程）

独立开发的 Mihomo 客户端，Windows 10/11 x64 优先，后续 Android、Linux。

**当前状态：界面预览 v0.2。不是可用代理客户端**——不含 Mihomo、未启用系统代理或 TUN。首页小组件、工具箱占位与导入预览可操作；内核诊断页可对用户自备的本机 Mihomo 做配置校验、启动、认证健康检查与停止（诊断模式不开放代理入口）。

## 运行与自检

需要 Flutter 3.47.8 / Dart 3.13.7；Windows 编译另需 Visual Studio Desktop development with C++。

```sh
flutter pub get
dart format lib test tool
flutter analyze
flutter test
flutter build windows --release   # 或由 GitHub Actions 的 desktop 工作流执行
```

真实内核诊断冒烟（不产生代理流量）：

```sh
dart run tool/core_smoke.dart <Mihomo 可执行文件绝对路径>
```

## 结构

- `lib/dashboard.dart`：小组件首页（添加/移除/拖动排序、原子保存布局）、工具箱、导入入口。
- `lib/main.dart`：主题与内核诊断页；离开页面即停止该页启动的内核，控制端口每次启动随机选取空闲端口。
- `lib/core/mihomo_controller.dart`：Mihomo 子进程生命周期与回环认证健康检查。
- `lib/profiles/`：订阅/节点导入预览（仅校验结构，不保存、不应用）。

进度、限制与交接状态见仓库根 `README.md` 与 `docs/`。

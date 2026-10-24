# M1：正式工程与内核适配

## 范围
- Flutter 3.47.8 / Dart 3.13.7，Windows、Android、Linux 平台工程。
- 当前原生界面是桌面内核诊断页，尚未迁移网页小组件桌面。
- 桌面 CoreAdapter：配置校验、子进程启动、随机认证密钥、回环健康检查、停止、启动失败处理。
- Android 禁用桌面内核启动入口；未实现 VpnService。

## 本机真实内核验证
使用官方 Mihomo v1.19.33 Windows amd64 compatible ZIP。
SHA256：`7aaf636a4f2172dcd8ec34ac4f52797b059195e5afd6409508c963e545f8864d`。
二进制只用于本地验证，未加入仓库或构建产物。

```powershell
dart tool/core_smoke.dart C:/absolute/path/mihomo.exe
```

已通过配置校验、启动、带认证的 /version 健康检查、停止。诊断配置关闭代理入口、TUN、DNS 劫持，不改变用户系统代理。

## 运行
```sh
cd apps/hotaru
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```
Windows 编译需要 Visual Studio 的 Desktop development with C++ 工作负载。本机尚未具备，因此本机未验证原生窗口和安装包。CI 配置执行 Windows 编译，并上传诊断预览目录；产物不包含 Mihomo，不是完整代理客户端。

## 已知限制与下一步
- 桌面正常退出回调负责停止；强制结束父进程尚无 Windows Job Object 保障。
- 诊断控制端口固定 19090，冲突时报错；不是正式配置管理。
- 原型小组件、订阅、系统代理、TUN、测速仍未迁移或接入。
- macOS 不属于当前交付平台；Android/Linux 平台目录已生成，但未实机验证。
- 尚未签名、未发布安装包；原生图标仍是 Flutter 模板，发布前替换。

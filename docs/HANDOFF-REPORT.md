# Hotaru 本轮完成与交还报告
- 日期：2026-10-24

- 工作仓库/分支：https://github.com/kurumiZafkiel12/Hotaru ，本地分支 `fix/core-lifecycle-layout-atomic`（从远端 main 新克隆，未触碰用户本机旧 checkout）

- 接手基线 commit：交接书所称 000f637eff4ca90f7b9d17d7c92bcc4fb2ffa737；实际远端 main 已前进一位至 c1baaaf626da08c501679639f7e0085bf000ffd2，该提交仅新增 `Hotaru-m2b-handoff.zip`（交接包），无代码变更。本轮以 c1baaaf 为基线。

- 最终 commit / PR：本地代码提交 3091526（其后另有一笔仅新增本报告的 docs 提交，为本地分支 HEAD）。**未推送、未建 PR**：Muse 的 GitHub App 对本仓库只有读取权限，创建分支与 push_files 均被 GitHub 返回 403 `Resource not accessible by integration`。需用户在 GitHub App 安装设置中为该仓库授予 Contents 写权限后，按本报告末尾步骤推送。

- Release 和直接下载链接：本轮**无新 Release**（未推送即无 CI 发布，绝不编造）。现存最新已验证发布仍为 preview-3：https://github.com/kurumiZafkiel12/Hotaru/releases/tag/preview-3 ，ZIP：https://github.com/kurumiZafkiel12/Hotaru/releases/download/preview-3/Hotaru-windows-x64-preview.zip

- 发布产物对应 commit、文件名、SHA256：preview-3 对应 000f637，`Hotaru-windows-x64-preview.zip`，SHA256 `aa6c20f91366b3940e01a14314322393deaffed7ea0bff3aed0bf415ca92cdde`。本轮在 Linux VM 内重新下载并校验，哈希一致；ZIP 内为 hotaru.exe + flutter_windows.dll + data/，不含 Mihomo。

## 第二轮增补（同日，用户明确要求“能像个代理软件使用”）
- 分支：`feat/minimal-proxy-loop`（叠在第一轮分支之上），版本升至 0.3.0+3。
- 推送记录（2026-10-24 12:42 后，用户指示「推」）：两轮全部 23 个变更文件经 GitHub 连接器以单个快照提交推送到 main（此前 GitHub App 写权限返回 403，用户处理后重试）。本文件随该提交一并上库；推送产生的 commit、CI 与 Release 编号以仓库 Actions / Releases 页为准，本文件不再事后改写以免触发重复发布。
- 完成且验证（证据均为本机实测）：
  - 协议扩展：SS（SIP002/旧式 Base64/obfs 与 v2ray-plugin）、VMess、VLESS（Reality/ws/grpc）、Hysteria2、Trojan 扩展参数、Base64 订阅。未知参数/字段一律拒绝。新增解析测试 9 项；六种样例生成的运行配置全部通过真实 Mihomo v1.19.33 的 `-t` 校验（VLESS 样例须用合法 Reality 公钥，假公钥被内核正确拒绝）。
  - 订阅保存与选择（C 核心）：`ProfileStore` 原子保存到 profiles-v1.json；导入失败不影响已有订阅；选择独立于原始配置保存；页面组件测试覆盖保存→重开恢复→坏导入不破坏→删除。
  - 代理闭环（E 核心）：`ProxyConfigBuilder`（HOTARU 选择组 + 自动选择 url-test 组；完整配置透传自身策略）+ `MihomoController.startRuntime` + `MihomoApi`（version/proxies/select/delay/connections）。`tool/proxy_loop_smoke.dart` 全本地端到端 PASS：上游 Mihomo SOCKS 监听作节点 → 导入 → 启动 → API 切换（注意：selectNode 已修复为优先 HOTARU 组而非 GLOBAL）→ delay 实测 7–8 ms → 经混合端口的 HTTP 请求成功且 `/connections` 链路证据为 [upstream-node, HOTARU] → 停止后端口关闭、请求失败、无残留进程。本轮还修复了生成 DNS 配置含 fallback 会触发 GeoIP 下载导致离线校验失败的问题（已移除 fallback）。
  - 系统代理（Windows）：注册表读/设/恢复适配器 + 原设置备份文件 + 遗留恢复入口；解析与命令序列由注入式假执行器单测覆盖。**Windows 实机未验证**，且未处理 WinINet 即时刷新通知。
  - 全量自检：flutter analyze 零问题；flutter test **38/38 通过**（第一轮 16 → 本轮 +22）；core_smoke 诊断冒烟继续 PASS。
- 仍未实现：TUN、分流规则编辑、下载测速、故障切换、多跳、连接记录页、流量统计、托盘、开机启动、provider-only 订阅、IP 质量数据源。真实公网节点未测（本机无用户节点凭据；链路已用本地真实内核双实例证明）。

## 本轮范围决定
按交接书推荐顺序执行 B（核心生命周期与布局保存修复）+ 技术债 #8/#9（品牌与文档一致性）。未做 A 的 Windows 原生截图验收（本环境无 Windows，不能伪造截图）；未扩大到 C/D/E（订阅保存、协议扩展、真实代理闭环、系统代理/TUN）。

## 完成且验证
| 功能 | 用户可见变化 | 核心文件 | 验证证据 |
|---|---|---|---|
| 诊断页离开即停内核 | 从工具箱进入内核诊断、启动内核后返回，子进程随页面销毁被停止，不再泄漏到应用退出 | `apps/hotaru/lib/main.dart`（dispose 调用 controller.dispose）、`lib/core/mihomo_controller.dart` | flutter test 16/16 通过；真实 Mihomo v1.19.33 冒烟 PASS 且结束后无残留进程（Linux） |
| dispose 语义硬化 | dispose 可重复调用、启动中调用不抛错；dispose 后再启动明确报 StateError；进程终止异常不再挂起调用方 | `lib/core/mihomo_controller.dart` | 新增单元测试 `dispose is idempotent, never throws, and blocks reuse` 通过 |
| 控制端口动态分配 | 不再固定 19090；每次启动先取空闲回环端口，端口被占不再直接导致诊断失败（竞态窗口已在代码注释中说明，绑定失败仍按启动失败处理） | `lib/core/mihomo_controller.dart`（findFreePort）、`lib/main.dart` | 新增测试 `findFreePort returns a bindable loopback port` 通过 |
| 布局原子保存 | 组件布局改为“临时文件写入+flush+重命名替换”；保存中崩溃只会损坏临时文件，上一份好布局保留；成功后无.tmp 残留 | `lib/dashboard.dart`（writeLayoutAtomically） | 新增测试覆盖二次覆盖写入与无临时文件残留，通过 |
| 损坏布局明确回退 | 布局文件存在但内容非法（非 JSON、类型错误、id 越界）时显示“布局读取失败，已使用默认布局。”，不再静默吞掉；重复 id 自动去重 | `lib/dashboard.dart`（tryParseLayout） | 新增单元测试 + 组件测试（写入 `###` 后警告与默认卡片均出现），通过 |
| 品牌/版本统一 v0.2 | pubspec 描述不再是 Flutter 模板文案，版本 1.0.0+1 → 0.2.0+2；首页标签 v0.1 → v0.2；Windows 资源 FileDescription/ProductName 改为 Hotaru | `apps/hotaru/pubspec.yaml`、`lib/dashboard.dart`、`apps/hotaru/windows/runner/Runner.rc`、`apps/hotaru/README.md`（模板 README 已替换为真实说明） | flutter analyze 零问题；Windows 资源实际生效需 CI 构建后人工核对（见“实现但未验证”） |
| 根 README 状态一致 | 删除“当前是网页交互原型、没有 Windows EXE”等过时表述；明确原生预览、下载链接与 SHA256、已实现/未实现边界 | `README.md` | 与 preview-3 实测下载内容逐项核对 |

## 实现但未验证
- Windows 原生构建与运行：本环境无 Visual Studio C++ 工具链，`flutter build windows --release` 未在本轮执行；Runner.rc 资源文案、原子保存中 rename 覆盖既有文件在 Windows 上的行为，需推送后由 GitHub Actions（windows-latest，工作流含 analyze/test/build）验证，本地测试注释已标明这一点。
- 页面销毁停内核的 Windows 实机行为：逻辑由单元/冒烟测试在 Linux 验证；Windows 原生窗口中导航返回的实际进程回收未人工验收。
- Android/Linux 实机：未验证（与基线相同）。
- 布局原子性在真实崩溃/断电时序下的表现：仅由实现方式与写入测试保证，未做故障注入。

## 尚未实现
- 真实代理流量：无。诊断模式仍 `mixed-port: 0`、mode direct，不产生代理。
- 系统代理、TUN：未实现，未改动任何系统网络设置。
- 协议：URI 仍仅 SOCKS5/HTTP(S)/基础 Trojan（仅 sni）；SS、VMess、VLESS、Hysteria2、Base64 订阅、provider-only 配置均未实现。
- 订阅/节点管理：导入仍只是结构预览，不保存、不应用、无回滚（C 阶段未启动）。
- 工具箱：节点测速、出口 IP、IP 质量、DNS 诊断仍为禁用占位，无任何模拟数据。
- 其余未实现：分流、自动选择、故障切换、多跳、连接记录、流量统计、托盘、开机启动、Job Object 子进程回收保障、安装/卸载、数字签名、正式开源许可证。

## 自检结果
| 命令/操作 | 结果 | 测试数量或 CI 链接 | 未覆盖部分 |
|---|---|---|---|
| `flutter pub get`（Flutter 3.47.8 / Dart 3.13.7，Linux x64，官方包 SHA256 已校验） | 成功，退出码 0 | — | — |
| `dart format lib test tool` | 成功；仅重新格式化新增测试文件 1 处 | 11 个文件 | — |
| `flutter analyze` | **No issues found**，退出码 0 | — | — |
| `flutter test` | **16/16 通过**（基线 11，本轮新增 5），退出码 0 | 按文件计：core_test 6（原 4+新 2）、dashboard_test 4（原 1+新 3）、importer_test 4、import_page_test 1、widget_test 1 | Windows 平台 test 待 CI |
| `dart run tool/core_smoke.dart /tmp/mihomo`（真实 Mihomo v1.19.33 linux-amd64-compatible，gz SHA256 `386508bfb1c72c43b6a0eda73708ecdce82546581b0ebcb16366c53757c622b6`） | PASS：配置校验、启动、认证 /version 健康检查、停止；结束后无残留 mihomo 进程 | 冒烟 1 项 | 仅诊断模式，非代理流量验证 |
| 重新下载 preview-3 ZIP 并 sha256sum | 与公布值一致 `aa6c20f9…cdde` | https://github.com/kurumiZafkiel12/Hotaru/releases/tag/preview-3 | 未在 Windows 解压运行 |
| GitHub 只读核对（list_commits / 公开 API） | 远端 main = c1baaaf；其 CI 两项成功：actions/runs/40055398777、40055398765；交接书 CI 40052365639（000f637）亦成功 | https://github.com/kurumiZafkiel12/Hotaru/actions/runs/40052365639 | 本轮代码的 CI 尚未产生（未推送） |
| `flutter build windows --release` | **未执行**（本环境为 Linux 且无 Windows 工具链） | 待推送后看 desktop 工作流 | Windows 原生验收整体待补 |
| 打开 Windows 原生程序 / 使用真实节点 / 退出后恢复网络 | **均未做**：无 Windows 环境、无真实节点；本轮未触碰系统网络，故无“恢复网络”事项 | — | A 阶段截图验收仍欠 |

## 本轮发现并修复的问题
1. CorePage.dispose 不停内核（技术债 #3 确认）：触发条件为从工具箱打开诊断页、启动内核后导航返回；子进程只能靠应用退出回调回收。修复：页面 dispose 中 `unawaited(core.dispose())`，并将 controller.dispose 改为幂等、busy 安全、永不抛错；回归测试见上表。
2. 布局非原子写入（技术债 #2 确认）：直接 writeAsString 覆盖目标文件，崩溃即损坏。修复：同目录临时文件 + flush + rename 替换，写串行队列保持不变；回归测试覆盖覆盖写与.tmp 残留。
3. 布局损坏被静默吞掉：文件存在但结构非法时旧代码不提示、直接默认。修复：统一走警告回退路径，并抽出 tryParseLayout 做范围/类型/去重校验。
4. 诊断端口固定 19090（技术债 #5 部分）：端口占用即失败且易与残留进程冲突。修复：每次启动 findFreePort 动态取空闲回环端口。
5. _terminate 脆弱：进程已退出等情况下 exitCode 等待可能抛错并向 dispose 传播。修复：终止改为 best-effort 并吞掉已退出异常。
6. HttpClient 无连接超时：为健康检查客户端设置 1 秒 connectionTimeout，与既有请求级超时一致。
7. 品牌残留（技术债 #8 部分）：pubspec 模板描述、apps/hotaru 模板 README、Runner.rc 小写模板名、根 README 过时状态（技术债 #9）。本轮一并清理；图标仍为 Flutter 模板图标，未替换。

## 已知问题与风险
- 残留进程：强制结束父进程时仍无 Windows Job Object 保障（技术债 #4 未处理）；正常导航/退出路径已覆盖。
- findFreePort 存在探测释放与内核绑定之间的固有竞态，极端情况下仍可能绑定失败，表现为普通启动失败，可重试。
- 数据存储：布局文件仍为明文 JSON（仅组件编号，无凭据）；订阅凭据存储方案未设计，属 C 阶段。
- 平台兼容：Windows 原生、Android、Linux 实机均未验收；rename 覆盖语义先由 Windows CI 的 flutter test 把关。
- 签名与许可证：产物未签名；正式开源许可证未定，公开仓库不等于授予许可；Mihomo 尚未随包分发。
- Hotaru-m2b-handoff.zip（95,994 字节）被提交在仓库根目录（c1baaaf），含交接材料；是否应保留在公开仓库请用户决定，本轮未删（删除属破坏性变更，未获指示）。

## 对原方案的调整
- 框架/依赖：无变化（Flutter 3.47.8、yaml、cupertino_icons 不变），未新增依赖。
- 配置格式：无变化；布局文件路径与格式不变（`layout-v1.json`，内容仍为组件编号数组），仅写入方式改为原子替换，旧文件完全兼容。
- 默认行为变化（均为修复）：①离开诊断页即停其内核；②诊断控制端口由固定改为随机空闲；③布局损坏时给出可见提示；④版本号升至 0.2.0+2。
- 目录：无变化；新增文件仅 `docs/HANDOFF-REPORT.md`。

## 本地与远端状态
- 远端：main 仍为 c1baaaf，未被修改；本轮分支未推送（权限 403，见抬头）；远端无新分支、无 PR、无 Release。
- 本地（执行本轮的 Linux VM）：`~/workspace/projects/Hotaru-fresh` 为全新克隆，分支 `fix/core-lifecycle-layout-atomic`，工作区干净；代码提交 3091526 + 本报告 docs 提交。另附同内容补丁/bundle 供本地应用。
- 用户本机旧 checkout（`C:/Users/kurumizafkiel/Documents/Codex/2026-10-24/w/outputs/Hotaru`，落后分支 m2-import）：本轮**未触碰**，未 pull/reset/清理，其未提交与未跟踪文件原样保留。
- 正在运行的进程/服务：无；冒烟用 Mihomo 已停止并确认无残留；Flutter SDK 仅解压在 VM 工作区。
- 修改过的系统设置：无。未动 Windows 系统代理、安全设置或计划任务。
- 未记录任何订阅密钥、密码或真实节点凭据（本轮未接触）。

## 交回 Codex 后的建议
1. 在 GitHub App 安装设置中允许 Muse 访问并写入 kurumiZafkiel12/Hotaru（Contents 权限），或由用户在本机将本地分支推送：`git push -u origin fix/core-lifecycle-layout-atomic`，随后建 PR 到 main；desktop 工作流会在 PR 上跑 analyze/test/Windows 构建，合并到 main 后自动发布下一 preview（预计 preview-4，以 Actions 实际编号为准）。
2. 在 Windows 10/11 解压新 preview，截首页/工具箱/导入/诊断四页图，重点反馈：首页纵向卡片是否要改多列自适应、组件尺寸、配色与字号；诊断页启动/返回后用任务管理器确认无残留 mihomo 进程。
3. 订阅预览推进为节点管理：候选模型 → Mihomo 语义校验 → 安全保存（原始订阅与用户覆写分离）→ 列表选择，失败保留上一份。入口文件：`lib/profiles/importer.dart`、`lib/profiles/import_page.dart`。
4. 按 SS → VMess → VLESS → Trojan 扩展 → Hysteria2 分批扩展 URI，每种配固定样例与负面用例，属性不得静默丢失。
5. 最小代理闭环：节点选择 → 配置生成 → `mihomo -t` 校验 → 启动 → 手动 HTTP/SOCKS 入口 → 真实请求验证 → 停止；通过后再接系统代理与 TUN，并补 Windows Job Object。
6. 决定仓库根 `Hotaru-m2b-handoff.zip` 去留；确定正式开源许可证后再考虑随包分发 Mihomo。

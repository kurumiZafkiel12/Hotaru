# 可选编辑器配置

项目协作规范统一从仓库根目录 `AGENTS.md` 进入，技能源文件位于 `.agents/skills/`。这里保存可选的编辑器、AI 客户端和 MCP 配置模板，不参与应用构建。

在仓库根目录按需复制；先检查本地已有配置，合并后再使用，避免覆盖个人设置。

| 工具 | 模板 | 本地路径 |
| --- | --- | --- |
| Claude Code | `claude/settings.json` | `.claude/settings.json` |
| Codex | `codex/config.toml` | `.codex/config.toml` |
| Gemini | `gemini/settings.json` | `.gemini/settings.json` |
| JetBrains | `jetbrains/` | `.run/` |
| Zed | `zed/` | `.zed/` |
| MCP 客户端 | `codegraph/mcp.json` | `.mcp.json` |
| OpenCode | `codegraph/opencode.jsonc` | `opencode.jsonc` |

Claude Code 的技能发现可在本地设置 `.claude/skills` 到 `../.agents/skills` 的目录符号链接；不支持符号链接的环境直接从 `AGENTS.md` 读取技能。CodeGraph 配置需要另行安装该命令。

客户端的即时钩子为可选功能；仓库的 pre-commit、pre-push 和 CI 检查继续保留。安全模式启动模板保留在 `jetbrains/main_safe_mode.run.xml` 和 `zed/` 中。以上本地路径均已加入 Git 忽略规则。

应用代码和命令工作目录为 `apps/hotaru/`；客户端模板安装位置仍相对仓库根目录。

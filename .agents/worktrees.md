# Worktrees

Claude Code, Codex, and Gemini each create git worktrees. `tool/worktrees.sh list` shows every worktree with its
owning tool and whether it holds uncommitted work; `tool/worktrees.sh prune` removes the clean ones and keeps
dirty ones unless `--force` is passed. The local `.claude/` directory is ignored by git; optional settings templates live in `apps/hotaru/tool/editor-config/`.

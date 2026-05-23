---
description: List all active worktrees with branch, dirty state, ahead/behind, and PR status
argument-hint: ""
allowed-tools: Bash
model: claude-haiku-4-5-20251001
---

# /work:list

Show every active worktree under `.worktrees/` with at-a-glance status.

## Run

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/list.sh"
```

That's the entire command. The script:

- enumerates worktrees (excluding the main checkout),
- per-worktree computes dirty marker / ahead-behind / PR state / last commit time,
- renders a compact table,
- prints a helpful empty-state message if no worktrees exist.

No further actions are needed. Pass the script's stdout through to the user.

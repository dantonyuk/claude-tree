---
description: Detailed status report for the current worktree
allowed-tools: Bash
model: claude-sonnet-4-6
---

# /work:status

Detailed report for the worktree the session is currently in.

## Run

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

That's the entire command. The script:

- refuses politely if not inside a worktree (and points at `/work:list` instead),
- otherwise renders branch / base / path / vs-upstream / vs-base / dirty files / commits-ahead / PR — without performing any fetch (read-only).

No further actions are needed.

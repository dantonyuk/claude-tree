---
description: Fetch and rebase the current worktree against its base branch
argument-hint: ""
allowed-tools: Bash, AskUserQuestion
---

# /work:sync

Bring the current worktree up to date with its base branch (rebase).

## Steps

1. **Check state.**

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" check
   ```

   Output is structured: `BRANCH=…`, `BASE=…`, `DIRTY=yes|no`. Non-zero exit → not in a worktree; the script printed the message, just stop.

2. **If `DIRTY=no`**, run directly:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" execute
   ```

3. **If `DIRTY=yes`**, use `AskUserQuestion` to confirm:

   - `"Stash, rebase, pop"` → run `"${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" execute --stash`
   - `"Commit first, then re-run"` → tell the user to commit and re-invoke `/work:sync`, then stop
   - `"Cancel"` → stop

The execute script handles fetch + rebase + (optional) stash-pop + final summary. On rebase conflict it prints remediation instructions and exits non-zero — pass that output through verbatim.

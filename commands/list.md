---
description: List all active worktrees with branch, dirty state, ahead/behind, and PR status
argument-hint: ""
allowed-tools: Bash
---

# /work:list

Show every active worktree under `.worktrees/` with at-a-glance status.

## Steps

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
wt_require_git || exit 1
MAIN=$(wt_main_dir)
```

1. **Enumerate worktrees** (excluding the main checkout):
   ```bash
   git -C "$MAIN" worktree list --porcelain
   ```
   Parse the porcelain output: each worktree is a block starting with `worktree <path>`, followed by `HEAD <sha>` and either `branch refs/heads/<name>` or `detached`. Skip the entry whose path equals `$MAIN`.

2. **For each non-main worktree**, gather:
   - `branch` — from `branch refs/heads/<name>` (or `(detached)`)
   - `dirty` — `[[ -n "$(git -C <path> status --porcelain)" ]] && echo "*" || echo " "`
   - `ahead/behind` — `git -C <path> rev-list --left-right --count '@{u}...HEAD' 2>/dev/null` → render as `+ahead/-behind`; show `—` if no upstream
   - `PR` — `wt_pr_for "$branch"` → render as `#N (state)` or `—`
   - `last commit` — `git -C <path> log -1 --format=%cr`

3. **Render a compact table:**
   ```
   | branch          | * | ahead/behind | PR              | last commit  |
   |-----------------|---|--------------|-----------------|--------------|
   | CORE-1234       | * | +3/-0        | #41 (OPEN)      | 2 hours ago  |
   | CORE-5678       |   | +0/-0        | —               | 1 day ago    |
   ```

4. **If no non-main worktrees exist**, print:
   ```
   No active worktrees. Use /work:start <branch> to create one.
   ```

## Notes

- Read-only; performs no mutations.
- Works from main checkout OR from inside any worktree (uses `wt_main_dir` to find the common root).
- If `gh` is missing, PR column shows `—` everywhere.

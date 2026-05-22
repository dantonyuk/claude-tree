---
description: Detailed status report for the current worktree
argument-hint: ""
allowed-tools: Bash
---

# /work:status

Detailed report for the worktree the session is currently in.

## Steps

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
wt_require_git || exit 1
```

1. **Refuse if not in a worktree** — direct the user to `/work:list` instead:
   ```bash
   if ! wt_in_worktree; then
     echo "Not inside a worktree. Use /work:list to see all worktrees from the main checkout."
     exit 0
   fi
   ```

2. **Collect:**
   - `BRANCH=$(git branch --show-current)`
   - `BASE=$(wt_default_branch)`
   - `WT_PATH=$(git rev-parse --show-toplevel)`
   - `MAIN=$(wt_main_dir)`
   - ahead/behind upstream → `wt_ahead_behind`
   - behind base → `git rev-list --count "HEAD..origin/$BASE" 2>/dev/null` (use local state; do NOT fetch from /work:status — that's /work:sync's job)
   - dirty files → `git status --short`
   - commits on this branch not on base → `git log --oneline "origin/$BASE..HEAD" 2>/dev/null`
   - PR info → `wt_pr_for "$BRANCH"`

3. **Render the report:**
   ```
   ─────────────────────────────────────────
    Worktree status
   ─────────────────────────────────────────
   branch:       <BRANCH>
   base:         <BASE>
   path:         <WT_PATH>
   main:         <MAIN>

   vs upstream:  <ahead>/<behind>     (or "no upstream set")
   vs base:      <behind> commits behind origin/<BASE>

   Dirty files:
     <output of git status --short, or "(none)">

   Commits on this branch:
     <output of git log --oneline origin/BASE..HEAD, or "(none yet)">

   PR:           #<N> (<STATE>) <URL>   (or "none")

   Next: /work:sync to rebase, /work:end to wrap up.
   ─────────────────────────────────────────
   ```

## Notes

- Read-only; does not fetch or mutate (status report only).
- If you want to refresh the "vs base" count, run `/work:sync` (which fetches).

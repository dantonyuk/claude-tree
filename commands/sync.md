---
description: Fetch and rebase the current worktree against its base branch
argument-hint: ""
allowed-tools: Bash, AskUserQuestion
---

# /work:sync

Bring the current worktree up to date with its base branch (rebase).

## Steps

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
wt_require_git || exit 1
```

1. **Refuse outside a worktree:**
   ```bash
   if ! wt_in_worktree; then
     echo "ERROR: /work:sync only runs inside a worktree."
     exit 1
   fi
   ```

2. **Resolve `BASE=$(wt_default_branch)`** and current `BRANCH=$(git branch --show-current)`.

3. **Handle a dirty working tree** with AskUserQuestion. Options:
   - "Stash, rebase, pop" — `git stash push -u -m "/work:sync auto-stash"` → rebase → `git stash pop`
   - "Commit current changes first" — instruct the user to commit, then re-run `/work:sync`
   - "Cancel"

   If clean, skip this prompt.

4. **Fetch the base:**
   ```bash
   git fetch origin "$BASE"
   ```

5. **Rebase:**
   ```bash
   git rebase "origin/$BASE"
   ```

6. **On rebase conflict** — DO NOT try to auto-resolve. Print:
   ```
   Rebase encountered conflicts. Resolve them, then run one of:
     git add <files> && git rebase --continue
     git rebase --abort
   ```
   and stop.

7. **On success** — print new state:
   ```bash
   echo "Sync complete. New status:"
   wt_ahead_behind   # ahead/behind upstream
   git rev-list --count HEAD.."origin/$BASE"   # behind base (should be 0)
   ```
   If the branch was previously pushed (upstream exists) and rebase moved commits, suggest:
   ```
   Note: history was rewritten; if this branch has been pushed, you'll need
     git push --force-with-lease
   ```

8. **If we stashed in step 3**, pop the stash. If pop conflicts, leave them for the user to resolve.

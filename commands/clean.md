---
description: Remove worktrees whose PRs are merged or closed (branches kept)
argument-hint: ""
allowed-tools: Bash, AskUserQuestion
---

# /work:clean

Find worktrees whose PR is merged or closed, and offer to remove them. Branches are always kept.

## Steps

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
wt_require_git || exit 1
```

1. **Require `gh`:**
   ```bash
   if ! wt_has_gh; then
     echo "ERROR: /work:clean needs the gh CLI to query PR status. Install gh or remove worktrees manually."
     exit 1
   fi
   ```

2. **Resolve `MAIN=$(wt_main_dir)`** and enumerate worktrees via `git -C "$MAIN" worktree list --porcelain`.

3. **For each non-main worktree**, get the branch name, then query:
   ```bash
   state=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null)
   ```
   Collect candidates where `state` is `MERGED` or `CLOSED`.

4. **If no candidates** → print "Nothing to clean (no worktrees with merged/closed PRs)." and exit.

5. **Show the candidates** in a table:
   ```
   | # | worktree path                 | branch     | PR state |
   |---|-------------------------------|------------|----------|
   | 1 | .../.worktrees/CORE-1111      | CORE-1111  | MERGED   |
   | 2 | .../.worktrees/CORE-2222      | CORE-2222  | CLOSED   |
   ```

6. **Use AskUserQuestion (multi-select)** with each candidate as one option labelled with branch + state. Add a "None of the above" option to allow bailing.

7. **For each selected worktree:**
   - Run a subshell `(cd "<path>" && wt_dirty)` — if dirty:
     - AskUserQuestion (per-worktree): "Worktree `<branch>` has uncommitted changes. (1) Skip this one. (2) Force-remove (discard work)."
   - Run a subshell `(cd "<path>" && wt_unpushed_count)` — if unpushed > 0 and PR state is CLOSED (not merged), warn but allow.
   - Then:
     ```bash
     git -C "$MAIN" worktree remove "<path>"     # or --force if user opted in
     ```

8. **Print summary:**
   ```
   Removed: <list>
   Skipped: <list with reason>
   Branches preserved: <list>
   ```

## Notes

- Never deletes branches — out of scope by design.
- Only acts on worktrees under `.worktrees/`; any external worktrees registered to the repo are listed but not touched.

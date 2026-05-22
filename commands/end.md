---
description: Tear down the current worktree after handling uncommitted/unpushed/missing-PR work
argument-hint: ""
allowed-tools: Bash, AskUserQuestion
---

# /work:end

Tear down the current worktree. If there's uncommitted work, unpushed commits, or no PR, prompt the user with a single combined choice before removing.

## Steps

Always source the helper library first:

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
wt_require_git || exit 1
```

1. **Refuse if not in a worktree:**
   ```bash
   if ! wt_in_worktree; then
     echo "ERROR: /work:end is only valid inside a worktree. Use /work:clean from main checkout to bulk-remove."
     exit 1
   fi
   ```

2. **Capture state BEFORE any cd or mutation:**
   ```bash
   WT_PATH=$(git rev-parse --show-toplevel)
   BRANCH=$(git branch --show-current)
   MAIN=$(wt_main_dir)
   BASE=$(wt_default_branch)
   ```

3. **Detect issues:**
   - `wt_dirty` returns 0 if dirty
   - `wt_unpushed_count` returns a number or "no-upstream"
   - `wt_pr_for "$BRANCH"` returns JSON if a PR exists, empty otherwise

4. **Show a one-screen summary** to the user (print to stdout):
   ```
   ─────────────────────────────────────────
    Ending worktree
   ─────────────────────────────────────────
   path:     <WT_PATH>
   branch:   <BRANCH>
   base:     <BASE>
   dirty:    <yes/no>  (N files)
   unpushed: <N commits | no upstream>
   PR:       <#N (STATE) URL | none>
   ─────────────────────────────────────────
   ```

5. **If clean AND has PR** → skip prompting; jump to step 8 (teardown).

6. **Otherwise, use AskUserQuestion once** with the question
   "How do you want to end this worktree?" and only offer the options that make sense for the current state:

   | Condition | Option label | Description |
   |---|---|---|
   | dirty, no PR | "Commit + push + open PR, then remove" | Stage all, draft commit message from diff, push with -u, `gh pr create --fill` |
   | dirty, has PR | "Commit + push, then remove" | Stage all, commit, push |
   | clean, unpushed, no PR | "Push + open PR, then remove" | Push and `gh pr create --fill` |
   | clean, unpushed, has PR | "Push, then remove" | Just push |
   | clean, no unpushed, no PR | "Open PR, then remove" | `gh pr create --fill` only |
   | always | "Remove anyway (keep branch; force if needed)" | `git worktree remove --force` after confirming uncommitted work will be discarded |
   | always | "Cancel" | Abort, no changes |

   Use grouped options — present only the rows whose condition matches.

7. **Execute the chosen action:**
   - **Commit step:** show the user `git diff --stat` and a 5-line preview of `git diff | head -50`. Draft a commit message from the diff (use the recent commit style — `git log --oneline -5` for tone). Then:
     ```bash
     git add -A
     git commit -m "<drafted message>"
     ```
   - **Push step:** set upstream if missing:
     ```bash
     if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
       git push
     else
       git push -u origin "$BRANCH"
     fi
     ```
   - **PR step:** `gh pr create --base "$BASE" --fill` — `--fill` uses commit messages for title/body. Refuse with a clear message if `gh` is missing.
   - **Remove anyway:** warn the user that uncommitted work in `<WT_PATH>` will be discarded. Use `git worktree remove --force "$WT_PATH"` in step 8.

8. **Teardown** — cd back to main, then remove:
   ```bash
   cd "$MAIN"
   git worktree remove "$WT_PATH"   # add --force only if the user picked "Remove anyway"
   ```

9. **Print confirmation:**
   ```
   Worktree removed:  <WT_PATH>
   Branch kept:       <BRANCH>  (still tracked locally)
   PR:                <#N URL | none>
   ```

## Failure handling

- If `git worktree remove` fails because the tree is still dirty and the user did NOT opt into "Remove anyway", report the error and stop without forcing.
- If any commit/push/PR step fails, stop before teardown so the user can resolve manually.

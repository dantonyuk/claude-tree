---
description: Tear down the current worktree after handling uncommitted/unpushed/missing-PR work
argument-hint: ""
allowed-tools: Bash, AskUserQuestion, ExitWorktree
---

# /work:end

Tear down the current worktree. If there is outstanding work (uncommitted changes, unpushed commits, no PR yet, …), prompt the user with one combined choice before removing. Always release the session from `EnterWorktree` before any `git worktree remove`.

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

3. **Detect issues.** Compute the following deterministically — every later branch in this command keys off these values:
   ```bash
   # Dirty flag (use as: `if wt_dirty; then ... fi`)
   # Unpushed commits relative to upstream (number or "no-upstream"):
   UNPUSHED=$(wt_unpushed_count)
   # PR state — one of MERGED, OPEN, CLOSED, or "none". Use gh's --jq so we don't
   # need a separate JSON parser. wt_pr_for already runs gh once; this second call
   # is cheap and avoids requiring jq.
   PR_STATE=none
   if wt_has_gh; then
     pr_state_raw=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null)
     [[ -n "$pr_state_raw" ]] && PR_STATE="$pr_state_raw"
   fi
   PR_URL=
   if wt_has_gh && [[ "$PR_STATE" != "none" ]]; then
     PR_URL=$(gh pr view "$BRANCH" --json url --jq '.url' 2>/dev/null)
   fi
   # Commits on this branch not yet on origin/$BASE. This is what /work:end cares
   # about — NOT @{u}, because the upstream is usually the same branch (so
   # @{u}..HEAD = 0 even when the branch has unique commits vs base).
   git fetch origin "$BASE" >/dev/null 2>&1 || true
   AHEAD_BASE=$(git rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)
   ```

4. **Show a one-screen summary** to the user. Render `nothing to PR — branch is at base` when `AHEAD_BASE == 0`:
   ```
   ─────────────────────────────────────────
    Ending worktree
   ─────────────────────────────────────────
   path:          <WT_PATH>
   branch:        <BRANCH>
   base:          <BASE>
   dirty:         <yes (N files) | no>
   unpushed:      <N commits | no upstream>
   ahead of base: <AHEAD_BASE> commits   (or "0 — nothing to PR; branch is at base")
   PR:            <#N (PR_STATE) URL | none>
   ─────────────────────────────────────────
   ```

5. **Auto-skip the action prompt ONLY when the worktree is clean AND `PR_STATE == MERGED`.** This is the only condition where the user clearly intends a routine teardown of merged work. For any other PR state (OPEN, CLOSED, none) — even with a clean tree — prompt in step 6 so the user can confirm.

   In the auto-skip path, the default branch action in step 7.5 is **`Delete branch (-d)`** since the PR is merged.

6. **Otherwise, use AskUserQuestion once** with the question
   "How do you want to end this worktree?". Show only the options whose conditions match the current state.

   | Condition | Option label | Notes |
   |---|---|---|
   | dirty, no PR, **AHEAD_BASE + dirty > 0** | "Commit + push + open PR, then remove" | Stage, commit, push -u, `gh pr create --fill` |
   | dirty, has PR | "Commit + push, then remove" | Stage, commit, push |
   | clean, unpushed > 0, no PR, **AHEAD_BASE > 0** | "Push + open PR, then remove" | Push and `gh pr create --fill` |
   | clean, unpushed > 0, has PR | "Push, then remove" | Just push |
   | clean, unpushed == 0, no PR, **AHEAD_BASE > 0** | "Open PR, then remove" | `gh pr create --fill` only |
   | always | "Remove anyway (keep branch; force if needed)" | Teardown only; uncommitted work discarded only if user confirms |
   | always | "Cancel" | Abort |

   **Hard rules**:
   - Never offer any "Open PR" variant when `AHEAD_BASE == 0` — `gh pr create --fill` would fail because there is nothing to PR.
   - If `AHEAD_BASE == 0` AND clean AND no PR, the only meaningful non-cancel option is "Remove anyway". Make that explicit in the summary: "branch has no commits ahead of base — nothing to PR; only removal is meaningful."

7. **Execute the chosen action:**
   - **Commit step:** show the user `git diff --stat` and `git diff | head -50`. Draft a commit message from the diff, calibrating tone to `git log --oneline -5`. Then:
     ```bash
     git add -A
     git commit -m "<drafted message>"
     ```
     After committing, re-compute `AHEAD_BASE` (it will have grown).
   - **Push step:** set upstream if missing:
     ```bash
     if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
       git push
     else
       git push -u origin "$BRANCH"
     fi
     ```
   - **PR step:** `gh pr create --base "$BASE" --fill`. Refuse with a clear message if `gh` is missing. Capture the resulting URL for the final summary.
   - **Remove anyway:** record that the user opted into `--force` for step 8c; warn that uncommitted work in `<WT_PATH>` will be discarded.

7.5. **Branch follow-up** — AskUserQuestion (single-select):
   "What should happen to branch `<BRANCH>` after the worktree is removed?"

   Defaults depend on `PR_STATE`:
   - `PR_STATE == MERGED` → present in order: **"Delete (`git branch -d`) [default]"**, "Keep", "Force-delete (`git branch -D`)"
   - any other `PR_STATE` (OPEN, CLOSED, none) → present in order: **"Keep [default]"**, "Delete (`git branch -d`)", "Force-delete (`git branch -D`)"

   Skip this prompt if the user picked "Cancel" in step 6.

8. **Teardown.** Follow this ordering exactly — it is the only sequence that works when the session entered the worktree via `EnterWorktree({ path })`:

   **a. Release the EnterWorktree session.** Always call `ExitWorktree` with `action: "keep"`. It is a documented no-op outside a managed session, so it is safe even if `/work:start` was not used (e.g., the user `cd`'d into the worktree manually, or the session is resumed across compaction without rerunning `/work:start`). **Never use `action: "remove"`** here — `ExitWorktree` refuses to remove path-entered worktrees and we already plan to use `git worktree remove` for cross-session compatibility.

   - **Tool call:** `ExitWorktree({ action: "keep" })`

   If the response is "No-op: there is no active EnterWorktree session to exit", treat this as success — the session was unmanaged, no release is needed, proceed to step 8b. Do not surface this as an error to the user.

   **b. Switch the bash subshell to the main checkout** so subsequent git commands run from there:
   ```bash
   cd "$MAIN"
   ```

   **c. Remove the worktree:**
   ```bash
   git worktree remove "$WT_PATH"           # add --force only if user picked "Remove anyway"
   ```

   **d. Branch action** (from step 7.5; skipped if the user cancelled):
   - **Keep** → do nothing.
   - **Delete** → `git branch -d "$BRANCH"`. If this fails because the branch has unmerged commits, **do not auto-escalate to `-D`**. Report the error verbatim and tell the user they can re-run `/work:end` and pick "Force-delete" if discarding is intended.
   - **Force-delete** → `git branch -D "$BRANCH"`.

9. **Print confirmation:**
   ```
   Worktree removed:  <WT_PATH>
   Branch:            <kept | deleted | force-deleted>   (BRANCH was <BRANCH>)
   PR:                <#N URL | none>
   ```

## Failure handling

- If `git worktree remove` fails because the tree is still dirty and the user did NOT opt into "Remove anyway", report the error and stop without forcing.
- If `git branch -d` refuses because the branch is unmerged, surface git's exact error and the suggested re-run path with force-delete; do not auto-escalate.
- If any commit/push/PR step fails, stop **before** step 8 so the user can resolve manually without losing the session reference to the worktree.

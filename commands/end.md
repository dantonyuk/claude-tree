---
description: Tear down the current worktree after handling uncommitted/unpushed/missing-PR work
argument-hint: ""
allowed-tools: Bash, AskUserQuestion, ExitWorktree
model: claude-sonnet-4-6
---

# /work:end

Tear down the current worktree. Handle outstanding work (uncommitted changes, unpushed commits, no PR) before removal, then always ask whether to delete the branch. Always release the `EnterWorktree` session before any `git worktree remove`.

## Steps

1. **Gather state.**

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/end.sh" prepare
   ```

   Parse stdout: `WT_PATH`, `BRANCH`, `MAIN`, `BASE`, `DIRTY` (yes/no), `UNPUSHED` (count or `no-upstream`), `PR_STATE` (`MERGED|OPEN|CLOSED|none`), `PR_URL`, `AHEAD_BASE`. Non-zero exit → not in a worktree; the script already printed the message — stop.

   Briefly tell the user the current state in one line (path / branch / dirty / unpushed / PR) so they have context for the next prompt.

2. **Auto-skip the action prompt** when `DIRTY=no` AND `PR_STATE=MERGED` (the routine post-ship teardown). Skip steps 3-4, go to step 5 with `BRANCH_ACTION=delete` as default.

3. **AskUserQuestion: "How do you want to end this worktree?"** Build the option list from this matrix — only include rows whose condition is true:

   | Condition | Option label | Action code |
   |---|---|---|
   | `DIRTY=yes` AND no PR AND (`DIRTY=yes` OR `AHEAD_BASE>0`) | "Commit + push + open PR, then remove" | `commit-push-pr` |
   | `DIRTY=yes` AND has PR | "Commit + push, then remove" | `commit-push` |
   | `DIRTY=no` AND `UNPUSHED>0` AND no PR AND `AHEAD_BASE>0` | "Push + open PR, then remove" | `push-pr` |
   | `DIRTY=no` AND `UNPUSHED>0` AND has PR | "Push, then remove" | `push` |
   | `DIRTY=no` AND `UNPUSHED=0` AND no PR AND `AHEAD_BASE>0` | "Open PR, then remove" | `pr` |
   | always | "Remove anyway (keep branch; force if needed)" | `none` (with `--force`) |
   | always | "Cancel" | abort |

   Never offer a PR option when `AHEAD_BASE=0` — `gh pr create --fill` fails with no diff. On Cancel → stop silently.

4. **Run the chosen action.** For `commit-push-pr` and `commit-push`, draft a commit message yourself from `git diff --stat` + `git diff` (calibrate tone to `git log --oneline -5`), then pass via `--message`:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/end.sh" act <action-code> [--message "<drafted msg>"] [--force]
   ```

   Captures `STATUS=ok|fail…`, `PR_URL` (empty if no PR was created), `FORCE_REMOVE=yes|no`. On non-`ok` status: surface the script's stderr and stop. For "Remove anyway": action code is `none`, pass `--force`.

5. **Branch follow-up — MANDATORY.** Runs whether you came from step 2 or step 4; only skipped on Cancel.

   **AskUserQuestion:** "What should happen to branch `<BRANCH>` after the worktree is removed?". Defaults depend on `PR_STATE`:
   - `PR_STATE=MERGED` → **"Delete (`git branch -d`)" [default]**, "Keep", "Force-delete (`git branch -D`)"
   - else → **"Keep" [default]**, "Delete (`git branch -d`)", "Force-delete (`git branch -D`)"

   Map to `BRANCH_ACTION` ∈ {`keep`, `delete`, `force-delete`}.

6. **Release the `EnterWorktree` session.** `ExitWorktree({ action: "keep" })`. Treat "no active session" as success. Never use `action: "remove"` — `ExitWorktree` refuses path-entered worktrees; we always use `git worktree remove`.

7. **Teardown.**

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/end.sh" teardown "<WT_PATH>" "<BRANCH>" "<MAIN>" "<BRANCH_ACTION>" [--force] [--pr-url "<PR_URL>"]
   ```

   Pass `--force` only if `FORCE_REMOVE=yes` from step 4. Pass `--pr-url` if non-empty. The script `cd`s to `<MAIN>`, removes the worktree, applies the branch action, prints the final confirmation. `git branch -d` refusal is not auto-escalated to `-D`.

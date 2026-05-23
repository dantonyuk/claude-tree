---
description: Tear down the current worktree after handling uncommitted/unpushed/missing-PR work
argument-hint: ""
allowed-tools: Bash, AskUserQuestion, ExitWorktree
---

# /work:end

Tear down the current worktree. If there is outstanding work (uncommitted changes, unpushed commits, no PR yet, …), prompt the user with one combined choice before removing. After that, **always** ask whether to delete the branch too (default `delete -d` when the PR is merged, default `keep` otherwise). Always release the session from `EnterWorktree` before any `git worktree remove`.

All git/PR work happens inside `scripts/end.sh`. This command orchestrates 2–3 bash calls (prepare → optional act → teardown) + AskUserQuestion(s) + 1 ExitWorktree tool call.

## Steps

1. **Prepare — gather state.**

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/end.sh" prepare
   ```

   stdout captures (parse line-by-line):
   `WT_PATH`, `BRANCH`, `MAIN`, `BASE`, `DIRTY` (yes/no), `UNPUSHED` (number or `no-upstream`), `PR_STATE` (`MERGED|OPEN|CLOSED|none`), `PR_URL`, `AHEAD_BASE` (count of commits not on `origin/$BASE`).

   stderr renders a human-readable summary the user will see. Non-zero exit → not in a worktree (script printed the message); just stop.

2. **Auto-skip the action prompt ONLY when `DIRTY=no` AND `PR_STATE=MERGED`.** That's the only routine-teardown case — the work is done and shipped. Skip step 3 and step 4; proceed straight to step 5 with **`BRANCH_ACTION=delete`** (since the PR is merged) as the default for step 5's prompt.

3. **Otherwise, AskUserQuestion ("How do you want to end this worktree?")** with grouped options. Build the option list according to this matrix — only include rows whose condition is true for the current state:

   | Condition | Option label | Internal action code |
   |---|---|---|
   | `DIRTY=yes` AND no PR AND (`DIRTY=yes` OR `AHEAD_BASE>0`) | "Commit + push + open PR, then remove" | `commit-push-pr` |
   | `DIRTY=yes` AND has PR | "Commit + push, then remove" | `commit-push` |
   | `DIRTY=no` AND `UNPUSHED>0` AND no PR AND `AHEAD_BASE>0` | "Push + open PR, then remove" | `push-pr` |
   | `DIRTY=no` AND `UNPUSHED>0` AND has PR | "Push, then remove" | `push` |
   | `DIRTY=no` AND `UNPUSHED=0` AND no PR AND `AHEAD_BASE>0` | "Open PR, then remove" | `pr` |
   | always | "Remove anyway (keep branch; force if needed)" | `none` (with `--force`) |
   | always | "Cancel" | abort |

   **Hard rules:**
   - Never offer any "Open PR" / "…+ open PR" variant when `AHEAD_BASE=0` — `gh pr create --fill` would fail (no diff). When `AHEAD_BASE=0` AND `DIRTY=no` AND no PR, the only meaningful option is "Remove anyway".

   On "Cancel" → stop silently. Don't run any further bash or tool calls.

4. **Run the chosen action — only one bash call.**

   For `commit-push-pr` and `commit-push`: first draft a commit message yourself from `git diff --stat` and `git diff` (calibrate tone to `git log --oneline -5`). Then pass it via `--message`.

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/end.sh" act <action-code> [--message "<drafted msg>"] [--force]
   ```

   Outputs `STATUS=ok|fail…`, `PR_URL=<url>` (empty if no PR was created), `FORCE_REMOVE=yes|no` (carry to step 6).

   - If `STATUS` is not `ok`, the script wrote diagnostics to stderr. Stop before step 6 so the user can resolve manually.
   - For the "Remove anyway" path, the action code is the literal string `none` and `--force` is passed; the script does no commit/push/PR, just sets `FORCE_REMOVE=yes`.

5. **Branch follow-up — MANDATORY.** This step runs whether you came from the auto-skip path (step 2) or the action path (step 4). It is only skipped if the user picked "Cancel" in step 3.

   **AskUserQuestion** with the question "What should happen to branch `<BRANCH>` after the worktree is removed?". Defaults depend on `PR_STATE`:

   - `PR_STATE=MERGED` → present in order: **"Delete (`git branch -d`)" [default]**, "Keep", "Force-delete (`git branch -D`)"
   - any other `PR_STATE` → present in order: **"Keep" [default]**, "Delete (`git branch -d`)", "Force-delete (`git branch -D`)"

   Map the user's choice to `BRANCH_ACTION` ∈ {`keep`, `delete`, `force-delete`}.

6. **Release the EnterWorktree session.**

   **Tool call:** `ExitWorktree({ action: "keep" })`.

   - If the response says "No-op: there is no active EnterWorktree session to exit", treat as success — the session was unmanaged, no release was needed.
   - **Never** use `action: "remove"` — `ExitWorktree` refuses to remove path-entered worktrees, and we always use `git worktree remove` instead.

7. **Teardown — one bash call.**

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/end.sh" teardown "<WT_PATH>" "<BRANCH>" "<MAIN>" "<BRANCH_ACTION>" [--force] [--pr-url "<PR_URL>"]
   ```

   Pass `--force` only if `FORCE_REMOVE=yes` from step 4. Pass `--pr-url` if `PR_URL` is non-empty (so the final summary shows the link). The script `cd`s to `<MAIN>`, removes the worktree, performs the branch action (with `-d` refusal not auto-escalated to `-D`), and prints the final confirmation.

## Failure handling

- If `git worktree remove` fails because the tree is dirty and the user did not choose "Remove anyway", the script reports the error and exits non-zero. Surface it; do not retry with `--force` automatically.
- If `git branch -d` refuses because the branch has unmerged commits, the script reports the warning, keeps the branch, and still exits 0 (the worktree is gone). The final confirmation shows "kept (delete refused)".
- If any commit/push/PR step (step 4) fails, stop **before** step 6 so the session reference to the worktree is preserved — the user can resolve manually and re-run.

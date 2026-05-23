---
description: Create or enter a git worktree (or, with no args, pick from existing ones)
argument-hint: "[branch-name] [base-branch]"
allowed-tools: Bash, AskUserQuestion, EnterWorktree, ExitWorktree
model: claude-sonnet-4-6
---

# /work:start [branch] [base]

Create a worktree at `<main>/.worktrees/<branch>`, or enter it if it already exists. With no args, opens an interactive picker over existing worktrees.

## Flow

### A — no args: picker

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/start.sh" candidates
```

First two stdout lines are header KEY=value pairs (`IN_WORKTREE=yes|no`, `ACTIVE_SESSION=yes|no`). Remaining lines are TSV (`<ts>\t<path>\t<branch>\t<dirty>\t<ahead>/<behind>\t<last_commit>`), most-recent first, current worktree excluded.

**No TSV rows:**
- `IN_WORKTREE=yes` → print `No other worktrees to switch to. Use /work:start <branch> to create a new one.` Stop.
- `IN_WORKTREE=no` → print:
  ```
  No existing worktrees found.

  usage:
    /work:start                          # pick from existing worktrees
    /work:start <branch>                 # create or enter <branch>
    /work:start <branch> <base>          # create from a specific base branch
  ```
  Stop.

**Candidates exist:** `AskUserQuestion` caps at 4 options. With "Cancel", show top 3 + Cancel. If >3 candidates, print the full numbered list first (branch / dirty / ahead-behind / last-commit) so the user sees everything; the auto-added "Other" lets them type any non-top-3 name.

Options: `{ label: <branch>, description: "<dirty>, <ahead>/<behind>, last commit <when>" }` per candidate, plus `{ label: "Cancel", description: "Don't enter any worktree" }`.

Response:
- Worktree label → use that row's `NAME`/`WT_PATH`. Go to **Enter**.
- `"Cancel"` → stop silently.
- `"Other"` (free text) → if it matches a branch in the candidate list, take that row's `WT_PATH` and go to **Enter**; otherwise restart as `/work:start <text>` (branch B).

### B — with args: create or detect

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/start.sh" prepare "$1" "$2"
```

Parse stdout: `NAME`, `BASE`, `MAIN`, `WT_PATH`, `IN_WORKTREE`, `CURRENT`, `ACTIVE_SESSION`, `EXISTING`, `FILES_COPIED`, `STATUS`. On `STATUS=ok` continue to **Enter**. On failure, surface the script's stderr and stop.

### Enter

**Short-circuit:** if `CURRENT=yes` (you're already in the target worktree), **skip steps 1 and 2** and go directly to step 3 — both `ExitWorktree` and `EnterWorktree` would either no-op or error on the current CWD.

1. **Release prior `EnterWorktree` session.** If `ACTIVE_SESSION=yes`, call `ExitWorktree({ action: "keep" })`. Otherwise skip. (`ACTIVE_SESSION` is the script's marker-file check — `yes` only when a previous `/work:start` in this CC session entered a worktree and `/work:end` hasn't run since.)

2. `EnterWorktree({ path: "<WT_PATH>" })`.

3. **Read worktree facts.**

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/start.sh" post-enter
   ```

   Emits `BRANCH`, `BASE`, `WT_PATH` on stdout. No banner, no stderr.

4. **Compose the "Worktree ready" banner.** Required for both branches and both new + existing worktrees. Type as plain text — no triple-backtick fence, no inline backticks, no markdown formatting. Substitute `<BRANCH>`, `<BASE>`, `<WT_PATH>`:

   ─────────────────────────────────────────
    Worktree ready
   ─────────────────────────────────────────
   branch:  <BRANCH>
   base:    <BASE>
   path:    <WT_PATH>

   Session is now switched to the worktree.

   Next: /rename <BRANCH>
   ─────────────────────────────────────────

   That is the entire assistant reply. No prose before or after.

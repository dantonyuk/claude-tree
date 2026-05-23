---
description: Create or enter a git worktree (or, with no args, pick from existing ones)
argument-hint: "[branch-name] [base-branch]"
allowed-tools: Bash, AskUserQuestion, EnterWorktree, ExitWorktree
model: claude-sonnet-4-6
---

# /work:start [branch] [base]

Create a worktree at `<main-tree>/.worktrees/<branch>` for the named branch, or enter it if it already exists. Default base = repo's default branch.

**No-argument mode:** with no args, an interactive picker shows existing worktrees to switch to.

All git/file work happens inside `scripts/start.sh`. This command is thin orchestration: 1 bash call to the script + tool calls for `ExitWorktree`/`EnterWorktree` + 1 zero-arg bash call after EnterWorktree to print the "Worktree ready" banner with the `/rename` hint.

## Flow

### Branch 1 — no arguments: picker

1. **Bash:**

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/start.sh" candidates
   ```

   First stdout line is `IN_WORKTREE=yes|no` (session state). Remaining lines are TSV candidates (one per row):
   `<ts>\t<path>\t<branch>\t<dirty>\t<ahead>/<behind>\t<last_commit>`. Already sorted by recency (most recent first). The current worktree (if any) is excluded.

2. **No candidates** (only the IN_WORKTREE header, no TSV rows):

   - If `IN_WORKTREE=yes` → print: `No other worktrees to switch to. Use /work:start <branch> to create a new one.` Stop.
   - If `IN_WORKTREE=no` → print the 3-line usage hint:
     ```
     No existing worktrees found.

     usage:
       /work:start                          # pick from existing worktrees
       /work:start <branch>                 # create or enter <branch>
       /work:start <branch> <base>          # create from a specific base branch
     ```
     Stop.

3. **Candidates exist — present a picker.** Cap is 4 options total in `AskUserQuestion`. With "Cancel" using one slot, you can show 3 worktree options. If more than 3 candidates: **print all candidates** (numbered, with each row's branch/dirty/ahead-behind/last-commit) to stdout *first*, **then** show the picker with the top 3 + Cancel. The auto-added "Other" lets the user type any non-top-3 name.

   For each picker option:
   - `label`: `<branch>`
   - `description`: `<dirty>, <ahead>/<behind>, last commit <when>`

   Always add `{ label: "Cancel", description: "Don't enter any worktree" }` as the final option.

   **Tool call:** `AskUserQuestion(...)`.

4. **Handle the response:**
   - A worktree label → set `NAME` and `WT_PATH` from that candidate's TSV row. Skip to **Enter** below.
   - `"Cancel"` → stop silently.
   - `"Other"` (free text) → treat as a branch argument:
     - if it matches a branch in the candidate list → take that row's `WT_PATH`, jump to **Enter**;
     - otherwise restart this whole command's flow as if the user typed `/work:start <text>` (i.e., proceed to Branch 2 with that name as `$1`).

### Branch 2 — with arguments: create or detect

1. **Bash:**

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/start.sh" prepare "$1" "$2"
   ```

   stdout captures (parse line-by-line): `NAME`, `BASE`, `MAIN`, `WT_PATH`, `IN_WORKTREE` (yes/no, session state at script start), `EXISTING` (yes/no — was the worktree pre-existing), then either `FILES_COPIED=…` and `STATUS=ok`, or `STATUS=failed-…` on error.

   - On `STATUS=ok` → continue to **Enter**.
   - On any failure → the script printed the git error to stderr; surface it to the user and stop.

### Enter (both branches converge here)

5. **Conditionally release a prior `EnterWorktree` session.** Use the `IN_WORKTREE` value captured above:

   - If `IN_WORKTREE=yes` → **Tool call:** `ExitWorktree({ action: "keep" })`. If the response says "no active EnterWorktree session", treat as success and proceed.
   - If `IN_WORKTREE=no` → **skip** the `ExitWorktree` call. Its no-op response renders as a misleading error in the CC UI when called from main, and we know there's nothing to release.

6. **Tool call:** `EnterWorktree({ path: "<WT_PATH>" })`. This switches the session's CWD properly (clears CWD-dependent caches).

7. **Read the worktree facts — MANDATORY.** Make this bash call with no arguments:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/start.sh" post-enter
   ```

   `post-enter` is self-contained: it infers everything from the worktree it's now running inside (because EnterWorktree changed the CWD). It emits ONLY structured stdout — three lines:
   - `BRANCH=<branch>`
   - `BASE=<base>`
   - `WT_PATH=<absolute path>`

   No banner, no stderr noise. The banner is your job in step 8.

8. **Compose the "Worktree ready" banner — MANDATORY, NON-NEGOTIABLE, applies to BOTH branches (picker + with-args), BOTH new + existing worktrees.**

   Type the following block as **plain text in your assistant reply** — no triple-backtick fence around it, no inline backticks anywhere inside it, no markdown formatting. Substitute the values from step 7's stdout. The final line `  /rename <branch>` is the entire reason this step exists: it lands in Claude Code's terminal CLI as a slash-command autocomplete suggestion in the user's input field, so a single Enter renames the session. The line MUST be indented exactly **2 spaces** (not 0, not 4 — 4 would turn it into a markdown code block and break the autocomplete pickup).

   Exact template — copy it verbatim and substitute the four placeholders:

   ─────────────────────────────────────────
    Worktree ready
   ─────────────────────────────────────────
   branch:  &lt;BRANCH&gt;
   base:    &lt;BASE&gt;
   path:    &lt;WT_PATH&gt;

   Session is now switched to the worktree.

   To rename this session to match the branch, type:
     /rename &lt;BRANCH&gt;

   Next: /work:status, /work:sync, /work:end
   ─────────────────────────────────────────

   That is the entire assistant reply. No prose before it, no prose after it. Just the banner. The two-space-indented `/rename <BRANCH>` line is what shows up as the input-box autocomplete suggestion.

## Failure handling

If any step before EnterWorktree fails, stop and surface the error. Never call EnterWorktree without a valid WT_PATH from the script. Never skip step 8 — without it the rename suggestion will not appear in the input box.

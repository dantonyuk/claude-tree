---
description: Create or enter a git worktree (or, with no args, pick from existing ones)
argument-hint: "[branch-name] [base-branch]"
allowed-tools: Bash, AskUserQuestion, Read, EnterWorktree, ExitWorktree
---

# /work:start [branch] [base]

Create a worktree at `<main-tree>/.worktrees/<branch>` for the named branch, or enter it if it already exists. Default base = repo's default branch (auto-detected from `origin/HEAD`).

**No-argument mode**: `/work:start` with no arguments shows an interactive picker of existing worktrees (or a usage hint if none exist). Picking one enters it directly without re-creating.

## Steps

Always source the helper library first:

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
wt_require_git || exit 1
```

1. **Parse arguments.** `$1` is the branch name (optional); `$2` is the base branch (optional).

   **If `$1` is provided**, set `NAME="$1"` and proceed to step 2 normally.

   **If `$1` is missing → picker mode.** Enumerate existing worktrees and present a picker.

   **Build the candidate list:**

   ```bash
   MAIN=$(wt_main_dir)
   CURRENT_WT=
   if wt_in_worktree; then
     CURRENT_WT=$(git rev-parse --show-toplevel)
   fi

   # Lines of "<unix_ts>\t<path>\t<branch>" for every non-main, non-current worktree,
   # sorted by last-commit time descending (most recent first).
   git -C "$MAIN" worktree list --porcelain | awk '
     /^worktree / { p = $2; next }
     /^branch refs\/heads\// { sub("refs/heads/", "", $2); print p "\t" $2 }
   ' | while IFS=$'\t' read -r p b; do
     [[ "$p" == "$MAIN" ]] && continue
     [[ -n "$CURRENT_WT" && "$p" == "$CURRENT_WT" ]] && continue
     ts=$(git -C "$p" log -1 --format=%ct 2>/dev/null || echo 0)
     printf '%s\t%s\t%s\n' "$ts" "$p" "$b"
   done | sort -rn
   ```

   **No candidates after exclusions:**
   - If the user is already in a worktree and no others exist, print:
     ```
     No other worktrees to switch to. Use /work:start <branch> to create a new one.
     ```
     and stop.
   - If no worktrees exist at all (running from main checkout, none under `.worktrees/`), print the 3-line usage hint and stop:
     ```
     No existing worktrees found.

     usage:
       /work:start                          # pick from existing worktrees
       /work:start <branch>                 # create or enter <branch>
       /work:start <branch> <base>          # create from a specific base branch
     ```

   **At least one candidate — prepare the picker.**

   Claude Code's `AskUserQuestion` is capped at **4 options total** (the UI auto-adds an "Other" / "Type something else" entry afterward). With "Cancel" occupying one slot, that leaves **3 worktree slots**.

   - If `N ≤ 3` candidates → all fit alongside Cancel; show the picker directly.
   - If `N > 3` → **first** print a numbered list of every candidate to stdout (so the user can see all of them, not just the top 3). Format each row as:
     ```
     <#>. <branch>   <clean|dirty>, <ahead>/<behind>, last commit <when>   (<path>)
     ```
     **Then** show the picker containing only the 3 most recent + Cancel. The auto-added "Other" lets the user type any branch name not in the top 3.

   For each option in the picker, the description should be short:
   `"<clean|dirty>, <ahead>/<behind>, last commit <when>"`

   **Tool call:** `AskUserQuestion({ questions: [{ question: "Which worktree do you want to enter?", header: "Worktree", multiSelect: false, options: [ ...up to 3 worktree options..., { label: "Cancel", description: "Don't enter any worktree" } ] }] })`

   **Handle the response:**
   - **Worktree label selected** → set `NAME` to that branch and `WT_PATH` to the corresponding path from the candidate list; jump directly to **step 8** (skip steps 2, 3, 4, 5, 6, 7 — worktree exists, nothing to validate, fetch, create, or copy).
   - **Cancel** → stop silently.
   - **Other** (user typed free text) → treat the text as a branch argument:
     - If it matches a branch in the candidate list, jump to step 8 like a normal selection.
     - Otherwise fall through and execute `/work:start <text>` end-to-end starting from step 2 (validate, possibly create). This means the picker doubles as an entry point for creating new worktrees too.

2. **Validate the branch name** before any mutation:
   ```bash
   git check-ref-format --branch "$1" || { echo "ERROR: invalid branch name: $1"; exit 1; }
   ```

3. **Resolve paths and base:**
   ```bash
   NAME="$1"
   MAIN=$(wt_main_dir)
   BASE="${2:-$(wt_default_branch)}"
   WT_PATH=$(wt_path "$NAME")
   ```

4. **Fetch the base branch** from origin (warn on failure but proceed — offline is OK):
   ```bash
   git -C "$MAIN" fetch origin "$BASE" || echo "WARNING: fetch of $BASE failed; continuing with local state"
   ```

5. **Skip creation if the worktree already exists.** Detect first; do the entry in step 8 (single code path):
   ```bash
   EXISTING=no
   if git -C "$MAIN" worktree list --porcelain | awk '/^worktree / {print $2}' | grep -Fxq "$WT_PATH"; then
     EXISTING=yes
     echo "Worktree already exists at $WT_PATH; entering it."
   fi
   ```
   If `EXISTING=yes`, **skip step 6 and step 7** (no creation, no file copy) and proceed to step 8.

6. **Create the worktree** based on existing branch state. Run `wt_branch_state "$NAME"` and act on the result:
   - `none` → brand-new branch off the base:
     ```bash
     git -C "$MAIN" worktree add -b "$NAME" "$WT_PATH" "origin/$BASE"
     ```
   - `local` → reuse local branch; notify the user it existed:
     ```bash
     echo "Note: branch '$NAME' already existed locally; reusing it."
     git -C "$MAIN" worktree add "$WT_PATH" "$NAME"
     ```
   - `remote` → fetch and check out remote branch:
     ```bash
     echo "Note: branch '$NAME' already existed on origin; checking it out."
     git -C "$MAIN" fetch origin "$NAME"
     git -C "$MAIN" worktree add "$WT_PATH" -b "$NAME" "origin/$NAME"
     ```
   - `both` → reuse local; if remote is ahead and ff-able, fast-forward local first:
     ```bash
     echo "Note: branch '$NAME' existed both locally and on origin; using local."
     if git -C "$MAIN" merge-base --is-ancestor "$NAME" "origin/$NAME" 2>/dev/null \
        && [ "$(git -C "$MAIN" rev-parse "$NAME")" != "$(git -C "$MAIN" rev-parse "origin/$NAME")" ]; then
       echo "Fast-forwarding local '$NAME' to match origin..."
       git -C "$MAIN" fetch origin "$NAME":"$NAME"
     fi
     git -C "$MAIN" worktree add "$WT_PATH" "$NAME"
     ```

7. **Copy gitignored root files** (env files, `.npmrc`, etc.) into the new worktree:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/copy-untracked.sh" "$MAIN" "$WT_PATH"
   ```

8. **Enter the worktree via the EnterWorktree built-in tool.** This properly switches the session's working directory and clears CWD-dependent caches (plans, memory, system prompt sections) — much cleaner than a bare `cd`.

   **Conditionally** release any prior `EnterWorktree` session first. Skip this call when starting from the main checkout — `ExitWorktree`'s "no active session" reply renders as a noisy "Error" in the CC UI even though it's just a documented no-op. We only need the release call when the session is already inside another worktree (i.e., the user is switching from one worktree to another in the same session):

   ```bash
   # Captured earlier in `wt_in_worktree`-aware logic; recompute if needed.
   if wt_in_worktree; then
     CALL_EXIT=yes
   else
     CALL_EXIT=no
   fi
   ```

   If `CALL_EXIT=yes`:
   - **Tool call:** `ExitWorktree({ action: "keep" })`
     (If the response says "no active EnterWorktree session", treat as success and proceed — we were in a worktree via bare `cd`, not via `EnterWorktree`. No further action needed.)

   Then enter the target worktree by absolute path **(always)**:

   - **Tool call:** `EnterWorktree({ path: "<absolute WT_PATH>" })`

   `EnterWorktree`'s `path` parameter accepts any worktree registered in `git worktree list`, so it works identically for newly-created and pre-existing worktrees.

9. **Print a summary** to the user. Include a rename suggestion unless the env var `CLAUDE_TREE_NO_RENAME=1` is set (check via `[[ "${CLAUDE_TREE_NO_RENAME:-}" == "1" ]]` in a quick Bash call before composing the message):
   ```
   ─────────────────────────────────────────
    Worktree ready
   ─────────────────────────────────────────
   branch:  <NAME>
   base:    <BASE>
   path:    <WT_PATH>
   files copied: <count from step 7, or "(skipped — entering existing)">

   Session is now switched to the worktree (EnterWorktree).

   To rename this session to match the branch, type:
     /rename <NAME>
   (Set CLAUDE_TREE_NO_RENAME=1 in your shell to suppress this hint.)

   Next: /work:status, /work:sync, /work:end
   ─────────────────────────────────────────
   ```

   If `CLAUDE_TREE_NO_RENAME=1` is set, omit the entire "To rename this session…" block (including the suppression hint).

## Failure handling

If any step errors, stop and surface the error verbatim. Do not attempt to continue past a failed worktree creation.

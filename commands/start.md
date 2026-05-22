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

   **If `$1` is missing → picker mode.** Enumerate existing worktrees (excluding the main checkout) and let the user pick one:

   ```bash
   MAIN=$(wt_main_dir)
   # Lines of "<path>\t<branch>" for each non-main worktree.
   git -C "$MAIN" worktree list --porcelain | awk '
     /^worktree / { p = $2; next }
     /^branch refs\/heads\// { sub("refs/heads/", "", $2); if (p != "'"$MAIN"'") print p "\t" $2 }
   '
   ```

   - **If the enumeration is empty**, print the usage hint and stop — do NOT proceed to step 2:
     ```
     No existing worktrees found.

     usage:
       /work:start                          # pick from existing worktrees
       /work:start <branch>                 # create or enter <branch>
       /work:start <branch> <base>          # create from a specific base branch
     ```

   - **If at least one worktree exists**, build option labels and present an `AskUserQuestion` picker:
     - For each worktree, compute via a `git -C <path>` subshell:
       - dirty? `[[ -n "$(git -C <path> status --porcelain)" ]]`
       - ahead/behind upstream: `git -C <path> rev-list --left-right --count '@{u}...HEAD' 2>/dev/null`, or "no upstream"
       - last commit: `git -C <path> log -1 --format=%cr`
     - **Tool call:** `AskUserQuestion({ questions: [{ question: "Which worktree do you want to enter?", header: "Worktree", multiSelect: false, options: [ { label: "<branch>", description: "<dirty marker>, <ahead>/<behind>, last commit <when>" }, ..., { label: "Cancel", description: "Don't enter any worktree" } ] }] })`
     - On "Cancel" → stop, print nothing.
     - On any worktree selection → set `NAME` to the picked branch and jump directly to **step 8** (enter via `EnterWorktree`). Skip steps 2, 3 (path computation can be inlined), 4, 5, 6, 7 — the worktree exists, there's nothing to fetch, validate, create, or copy.

       For step 8 you still need `WT_PATH`; compute it from the picker's selected worktree path directly (the picker had it available).

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

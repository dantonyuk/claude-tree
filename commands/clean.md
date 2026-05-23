---
description: Remove worktrees whose PRs are merged or closed (branches kept)
allowed-tools: Bash, AskUserQuestion
model: claude-sonnet-4-6
---

# /work:clean

Find worktrees whose PR is `MERGED` or `CLOSED`, and offer to remove them. Branches are always kept.

## Steps

1. **List candidates.**

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/clean.sh" candidates
   ```

   Output is TSV — one line per candidate: `<path>\t<branch>\t<state>\t<dirty>\t<unpushed>`. Empty output → nothing to clean → print "Nothing to clean (no worktrees with merged/closed PRs)." and stop.

   The script errors with exit 1 if `gh` is missing. Pass that message through.

2. **Present candidates with AskUserQuestion (multiSelect=true).**

   `AskUserQuestion` caps at 4 options. Show top 3 most-recently-MERGED (or script order if you can't sort by merge time) + "None / cancel". If >3 candidates, print the full numbered list first; the auto-added "Other" lets the user type any non-top-3 name.

   Each option's label is `<branch> (<STATE>)`, description includes dirty/unpushed flags.

3. **For each selected candidate**:

   - If `dirty=yes` or `unpushed > 0`, **AskUserQuestion (per worktree)**: "Worktree `<branch>` has local changes. Skip / Force-remove (discards work)?". Only proceed if user opted into force.
   - Run:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/clean.sh" remove "<path>" [--force]
     ```
     `--force` only if the per-worktree confirmation explicitly chose it.

4. **Print a brief summary** of what was removed and what was skipped (and why).

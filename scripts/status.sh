#!/usr/bin/env bash
# scripts/status.sh — implementation of /work:status. Read-only one-shot report.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

wt_require_git || exit 1

if ! wt_in_worktree; then
  echo "Not inside a worktree. Use /work:list to see all worktrees from the main checkout."
  exit 0
fi

BRANCH=$(git branch --show-current)
BASE=$(wt_default_branch)
WT_PATH=$(git rev-parse --show-toplevel)
MAIN=$(wt_main_dir)

# Ahead/behind upstream (or "no upstream")
ab=$(wt_ahead_behind)
if [[ "$ab" == "no-upstream" ]]; then
  upstream_str="no upstream set"
else
  behind=$(echo "$ab" | awk '{print $1}')
  ahead=$(echo "$ab" | awk '{print $2}')
  upstream_str="$ahead ahead, $behind behind"
fi

# Behind base (no fetch — status is local-state only)
behind_base=$(git rev-list --count "HEAD..origin/$BASE" 2>/dev/null || echo 0)
ahead_base=$(git rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)

# Dirty files
dirty_files=$(git status --short 2>/dev/null)

# Commits ahead of base
commits_ahead=$(git log --oneline "origin/$BASE..HEAD" 2>/dev/null)

# PR info
pr_str="none"
if wt_has_gh; then
  pr_state=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null || echo "")
  if [[ -n "$pr_state" ]]; then
    pr_num=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "?")
    pr_url=$(gh pr view "$BRANCH" --json url --jq '.url' 2>/dev/null || echo "")
    pr_str="#$pr_num ($pr_state) $pr_url"
  fi
fi

cat <<EOF
─────────────────────────────────────────
 Worktree status
─────────────────────────────────────────
branch:        $BRANCH
base:          $BASE
path:          $WT_PATH
main:          $MAIN

vs upstream:   $upstream_str
vs base:       $ahead_base ahead, $behind_base behind origin/$BASE

Dirty files:
EOF

if [[ -z "$dirty_files" ]]; then
  echo "  (none)"
else
  echo "$dirty_files" | sed 's/^/  /'
fi

echo ""
echo "Commits on this branch (vs base):"
if [[ -z "$commits_ahead" ]]; then
  echo "  (none yet)"
else
  echo "$commits_ahead" | sed 's/^/  /'
fi

echo ""
printf 'PR:            %s\n' "$pr_str"
echo ""
echo "Next: /work:sync to rebase, /work:end to wrap up."
echo "─────────────────────────────────────────"

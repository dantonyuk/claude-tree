#!/usr/bin/env bash
# scripts/list.sh — implementation of /work:list. One-shot table render.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

wt_require_git || exit 1
MAIN=$(wt_main_dir)

# Gather worktrees other than main.
WORKTREES=()
while IFS=$'\t' read -r p b; do
  [[ "$p" == "$MAIN" ]] && continue
  WORKTREES+=("$p"$'\t'"$b")
done < <(git -C "$MAIN" worktree list --porcelain | awk '
  /^worktree / { p = $2; next }
  /^branch refs\/heads\// { sub("refs/heads/", "", $2); print p "\t" $2 }
')

if [[ ${#WORKTREES[@]} -eq 0 ]]; then
  echo "No active worktrees. Use /work:start <branch> to create one."
  exit 0
fi

printf '%-32s %-3s %-14s %-18s %s\n' 'branch' 'dty' 'ahead/behind' 'PR' 'last commit'
printf '%-32s %-3s %-14s %-18s %s\n' '------' '---' '------------' '--' '-----------'

for entry in "${WORKTREES[@]}"; do
  p="${entry%%$'\t'*}"
  b="${entry#*$'\t'}"

  dirty=" "
  [[ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]] && dirty="*"

  ab_str="—"
  if ab=$(git -C "$p" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
    behind=$(echo "$ab" | awk '{print $1}')
    ahead=$(echo "$ab" | awk '{print $2}')
    ab_str="+$ahead/-$behind"
  fi

  pr="—"
  if wt_has_gh; then
    pr_state=$(gh pr view "$b" --json state --jq '.state' 2>/dev/null || echo "")
    if [[ -n "$pr_state" ]]; then
      pr_num=$(gh pr view "$b" --json number --jq '.number' 2>/dev/null || echo "?")
      pr="#$pr_num ($pr_state)"
    fi
  fi

  last=$(git -C "$p" log -1 --format=%cr 2>/dev/null || echo unknown)

  printf '%-32s %-3s %-14s %-18s %s\n' "$b" "$dirty" "$ab_str" "$pr" "$last"
done

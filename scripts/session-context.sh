#!/usr/bin/env bash
# SessionStart hook: emit a short context block describing whether this
# Claude Code session is in the main checkout or a worktree.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

MAIN=$(wt_main_dir 2>/dev/null) || exit 0
REPO_NAME=$(basename "$MAIN")

emit() { printf '%s\n' "$*"; }

if wt_in_worktree; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  [[ -z "$BRANCH" ]] && BRANCH="(detached HEAD)"

  emit "[work plugin] Session is in WORKTREE \"$BRANCH\" of repo \"$REPO_NAME\"."
  emit "  Main checkout: $MAIN"
  emit "  Worktree path: $(git rev-parse --show-toplevel)"

  ab=$(wt_ahead_behind)
  if [[ "$ab" == "no-upstream" ]]; then
    emit "  Upstream: not set (branch has not been pushed yet)"
  else
    behind=$(echo "$ab" | awk '{print $1}')
    ahead=$(echo "$ab" | awk '{print $2}')
    emit "  vs upstream: $ahead ahead, $behind behind"
  fi

  if wt_has_gh; then
    if gh pr view "$BRANCH" --json number >/dev/null 2>&1; then
      num=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "?")
      state=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null || echo "?")
      url=$(gh pr view "$BRANCH" --json url --jq '.url' 2>/dev/null || echo "")
      emit "  PR: #$num ($state) $url"
    else
      emit "  PR: none open for this branch"
    fi
  else
    emit "  PR: (gh not installed; PR status unknown)"
  fi

  emit ""
  emit "  Tip: /work:status for details, /work:sync to rebase, /work:end to tear down."
else
  emit "[work plugin] Session is in MAIN checkout of repo \"$REPO_NAME\" ($MAIN)."

  others=$(git -C "$MAIN" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / {print $2}' \
    | grep -v "^${MAIN}$" || true)

  if [[ -n "$others" ]]; then
    count=$(printf '%s\n' "$others" | wc -l | tr -d ' ')
    names=$(printf '%s\n' "$others" | xargs -n1 basename 2>/dev/null | paste -sd, - | sed 's/,/, /g')
    emit "  Active worktrees ($count): $names"
  else
    emit "  No active worktrees yet."
  fi

  emit "  Tip: /work:start <branch> [base] to create one. /work:list to see all."
fi

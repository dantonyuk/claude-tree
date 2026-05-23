#!/usr/bin/env bash
# scripts/end.sh — backing logic for /work:end.
#
# Subcommands:
#   prepare                                       gather state of current worktree
#   act <action> [--message "<msg>"]              perform commit/push/PR action
#   teardown <wt_path> <branch> <main> <branch_action> [--force] [--pr-url <url>]
#
# Actions: commit-push-pr | commit-push | push-pr | push | pr | none
# Branch actions: keep | delete | force-delete

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
usage:
  $(basename "$0") prepare
  $(basename "$0") act <action> [--message "<msg>"]
      actions: commit-push-pr | commit-push | push-pr | push | pr | none
  $(basename "$0") teardown <wt_path> <branch> <main> <branch_action> [--force] [--pr-url <url>]
      branch_action: keep | delete | force-delete
EOF
  exit 2
}

cmd_prepare() {
  wt_require_git || exit 1
  if ! wt_in_worktree; then
    echo "ERROR: /work:end is only valid inside a worktree." >&2
    exit 1
  fi

  local WT_PATH BRANCH MAIN BASE DIRTY UNPUSHED PR_STATE PR_URL AHEAD_BASE
  WT_PATH=$(git rev-parse --show-toplevel)
  BRANCH=$(git branch --show-current)
  MAIN=$(wt_main_dir)
  BASE=$(wt_default_branch)

  DIRTY=no
  wt_dirty && DIRTY=yes

  UNPUSHED=$(wt_unpushed_count)

  PR_STATE=none
  PR_URL=
  if wt_has_gh; then
    local s
    s=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null || echo "")
    if [[ -n "$s" ]]; then
      PR_STATE="$s"
      PR_URL=$(gh pr view "$BRANCH" --json url --jq '.url' 2>/dev/null || echo "")
    fi
  fi

  git fetch origin "$BASE" >/dev/null 2>&1 || true
  AHEAD_BASE=$(git rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)

  # Structured output for the LLM (which composes the user-facing summary
  # from these fields — no duplicate banner on stderr).
  cat <<EOF
WT_PATH=$WT_PATH
BRANCH=$BRANCH
MAIN=$MAIN
BASE=$BASE
DIRTY=$DIRTY
UNPUSHED=$UNPUSHED
PR_STATE=$PR_STATE
PR_URL=$PR_URL
AHEAD_BASE=$AHEAD_BASE
EOF
}

cmd_act() {
  local action="${1:-}"
  shift || true
  local msg="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --message) msg="${2:-}"; shift 2 ;;
      --force)   force=1; shift ;;
      *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
  done
  [[ -z "$action" ]] && { echo "ERROR: act requires an action" >&2; exit 2; }

  wt_require_git || exit 1
  wt_in_worktree || { echo "ERROR: act must run inside a worktree" >&2; exit 1; }

  local BASE BRANCH PR_URL=""
  BASE=$(wt_default_branch)
  BRANCH=$(git branch --show-current)

  # COMMIT phase
  case "$action" in
    commit-push-pr|commit-push)
      [[ -z "$msg" ]] && { echo "ERROR: $action requires --message" >&2; exit 2; }
      echo "==> committing all changes..." >&2
      git add -A || { echo "ERROR: git add failed" >&2; exit 1; }
      git commit -m "$msg" || { echo "ERROR: git commit failed" >&2; exit 1; }
      ;;
  esac

  # PUSH phase
  case "$action" in
    commit-push-pr|commit-push|push-pr|push)
      echo "==> pushing..." >&2
      if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        git push >&2 || { echo "ERROR: git push failed" >&2; exit 1; }
      else
        git push -u origin "$BRANCH" >&2 || { echo "ERROR: git push -u failed" >&2; exit 1; }
      fi
      ;;
  esac

  # PR phase
  case "$action" in
    commit-push-pr|push-pr|pr)
      wt_has_gh || { echo "ERROR: gh CLI required for PR creation" >&2; exit 1; }
      echo "==> creating PR..." >&2
      local out
      if out=$(gh pr create --base "$BASE" --fill 2>&1); then
        PR_URL=$(echo "$out" | grep -oE 'https://[^[:space:]]+' | head -1 || echo "")
      else
        echo "ERROR: gh pr create failed:" >&2
        echo "$out" >&2
        exit 1
      fi
      ;;
  esac

  # Structured outcomes
  printf 'STATUS=ok\n'
  printf 'PR_URL=%s\n' "$PR_URL"
  printf 'FORCE_REMOVE=%s\n' "$([[ $force -eq 1 ]] && echo yes || echo no)"
}

cmd_teardown() {
  local wt_path="${1:-}" branch="${2:-}" main="${3:-}" branch_action="${4:-keep}"
  shift 4 2>/dev/null || true
  local force=0 pr_url=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)  force=1; shift ;;
      --pr-url) pr_url="${2:-}"; shift 2 ;;
      *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  if [[ -z "$wt_path" || -z "$branch" || -z "$main" ]]; then
    echo "ERROR: teardown requires <wt_path> <branch> <main> <branch_action>" >&2
    exit 2
  fi

  cd "$main" || { echo "ERROR: cannot cd to main: $main" >&2; exit 1; }

  echo "==> removing worktree $wt_path" >&2
  if (( force )); then
    git worktree remove --force "$wt_path" || { echo "ERROR: worktree remove --force failed" >&2; exit 1; }
  else
    git worktree remove "$wt_path" || {
      echo "ERROR: worktree remove failed (re-run /work:end and pick 'Remove anyway' to force)" >&2
      exit 1
    }
  fi

  local branch_result="kept"
  case "$branch_action" in
    keep) : ;;
    delete)
      if git branch -d "$branch" >&2 2>&1; then
        branch_result="deleted"
      else
        echo "WARNING: 'git branch -d $branch' refused; branch has unmerged commits. Branch kept." >&2
        echo "         re-run /work:end and pick 'Force-delete' if you want to discard them." >&2
        branch_result="kept (delete refused)"
      fi
      ;;
    force-delete)
      git branch -D "$branch" >&2 2>&1 || { echo "ERROR: git branch -D failed" >&2; exit 1; }
      branch_result="force-deleted"
      ;;
    *)
      echo "ERROR: invalid branch_action: $branch_action" >&2
      exit 2
      ;;
  esac

  echo ""
  printf 'Worktree removed:  %s\n' "$wt_path"
  printf 'Branch:            %s  (%s)\n' "$branch_result" "$branch"
  if [[ -n "$pr_url" ]]; then
    printf 'PR:                %s\n' "$pr_url"
  fi
}

case "${1:-}" in
  prepare)  shift; cmd_prepare "$@" ;;
  act)      shift; cmd_act "$@" ;;
  teardown) shift; cmd_teardown "$@" ;;
  ""|-h|--help) usage ;;
  *)        echo "unknown subcommand: $1" >&2; usage ;;
esac

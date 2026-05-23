#!/usr/bin/env bash
# scripts/sync.sh — backing logic for /work:sync.
#
# Subcommands:
#   check                 emit structured state for the markdown to decide
#   execute [--stash]     do the fetch + rebase (optionally stash first)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
usage:
  $(basename "$0") check
  $(basename "$0") execute [--stash]
EOF
  exit 2
}

cmd_check() {
  wt_require_git || exit 1
  if ! wt_in_worktree; then
    echo "ERROR: /work:sync only runs inside a worktree." >&2
    exit 1
  fi
  local BRANCH BASE DIRTY
  BRANCH=$(git branch --show-current)
  BASE=$(wt_default_branch)
  DIRTY=no
  wt_dirty && DIRTY=yes
  cat <<EOF
BRANCH=$BRANCH
BASE=$BASE
DIRTY=$DIRTY
EOF
}

cmd_execute() {
  local do_stash=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stash) do_stash=1; shift ;;
      *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  wt_require_git || exit 1
  wt_in_worktree || { echo "ERROR: must be in worktree" >&2; exit 1; }

  local BASE BRANCH stashed=0
  BASE=$(wt_default_branch)
  BRANCH=$(git branch --show-current)

  if (( do_stash )); then
    if wt_dirty; then
      git stash push -u -m "/work:sync auto-stash" >&2 || { echo "ERROR: stash failed" >&2; exit 1; }
      stashed=1
    fi
  fi

  git fetch origin "$BASE" >&2 || { echo "ERROR: fetch failed" >&2; exit 1; }

  if ! git rebase "origin/$BASE" >&2; then
    echo "" >&2
    echo "Rebase encountered conflicts. Resolve them, then run one of:" >&2
    echo "  git add <files> && git rebase --continue" >&2
    echo "  git rebase --abort" >&2
    if (( stashed )); then
      echo "" >&2
      echo "(After resolving rebase, run 'git stash pop' to restore your local changes.)" >&2
    fi
    exit 1
  fi

  # Pop stash if we stashed
  if (( stashed )); then
    if ! git stash pop >&2; then
      echo "WARNING: 'git stash pop' had conflicts; resolve manually (git stash list to verify)." >&2
    fi
  fi

  # Summary
  local ab behind ahead behind_base
  if ab=$(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
    behind=$(echo "$ab" | awk '{print $1}')
    ahead=$(echo "$ab" | awk '{print $2}')
  else
    behind=0; ahead=0
  fi
  behind_base=$(git rev-list --count "HEAD..origin/$BASE" 2>/dev/null || echo 0)

  echo ""
  echo "Sync complete."
  printf '  vs upstream: %s ahead, %s behind\n' "$ahead" "$behind"
  printf '  vs base:     %s behind origin/%s\n' "$behind_base" "$BASE"

  if [[ "$ahead" != "0" ]] && git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    echo ""
    echo "Note: rebase rewrote history. If this branch is already pushed:"
    echo "  git push --force-with-lease"
  fi
}

case "${1:-}" in
  check)   shift; cmd_check "$@" ;;
  execute) shift; cmd_execute "$@" ;;
  ""|-h|--help) usage ;;
  *)       echo "unknown subcommand: $1" >&2; usage ;;
esac

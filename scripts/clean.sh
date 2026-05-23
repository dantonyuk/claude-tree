#!/usr/bin/env bash
# scripts/clean.sh — backing logic for /work:clean.
#
# Subcommands:
#   candidates              list worktrees whose PR is MERGED or CLOSED (TSV)
#   remove <path> [--force] remove one worktree under .worktrees/

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
usage:
  $(basename "$0") candidates
  $(basename "$0") remove <wt_path> [--force]
EOF
  exit 2
}

cmd_candidates() {
  wt_require_git || exit 1
  if ! wt_has_gh; then
    echo "ERROR: /work:clean needs the gh CLI to query PR status. Install gh or remove worktrees manually." >&2
    exit 1
  fi
  local MAIN
  MAIN=$(wt_main_dir)

  # Output for each candidate: <path>\t<branch>\t<state>\t<dirty>\t<unpushed_count_or_no-upstream>
  git -C "$MAIN" worktree list --porcelain | awk '
    /^worktree / { p = $2; next }
    /^branch refs\/heads\// { sub("refs/heads/", "", $2); print p "\t" $2 }
  ' | while IFS=$'\t' read -r p b; do
    [[ "$p" == "$MAIN" ]] && continue
    local state
    state=$(gh pr view "$b" --json state --jq '.state' 2>/dev/null || echo "")
    case "$state" in
      MERGED|CLOSED) ;;
      *) continue ;;
    esac
    local dirty=no
    [[ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]] && dirty=yes
    local unpushed
    if git -C "$p" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      unpushed=$(git -C "$p" rev-list '@{u}..HEAD' --count 2>/dev/null || echo 0)
    else
      unpushed=no-upstream
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$b" "$state" "$dirty" "$unpushed"
  done
}

cmd_remove() {
  local wt_path="${1:-}" force=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
  done
  [[ -z "$wt_path" ]] && { echo "ERROR: remove requires <wt_path>" >&2; exit 2; }

  wt_require_git || exit 1
  local MAIN
  MAIN=$(wt_main_dir)

  if (( force )); then
    git -C "$MAIN" worktree remove --force "$wt_path" >&2 || { echo "ERROR: force-remove failed" >&2; exit 1; }
  else
    git -C "$MAIN" worktree remove "$wt_path" >&2 || {
      echo "ERROR: worktree remove failed (use --force to discard local changes)" >&2
      exit 1
    }
  fi

  printf 'REMOVED=%s\n' "$wt_path"
}

case "${1:-}" in
  candidates) shift; cmd_candidates "$@" ;;
  remove)     shift; cmd_remove "$@" ;;
  ""|-h|--help) usage ;;
  *)          echo "unknown subcommand: $1" >&2; usage ;;
esac

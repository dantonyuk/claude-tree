#!/usr/bin/env bash
# scripts/start.sh — backing logic for /work:start.
#
# Subcommands:
#   candidates                       enumerate switchable worktrees (no-arg picker)
#   prepare <name> [base]            validate, fetch, create-or-detect, copy env files
#   post-enter                       print the user-facing "Worktree ready" + /rename
#                                    banner from inside the worktree (run AFTER
#                                    EnterWorktree; takes no args, infers everything
#                                    from current git state)
#   summary <name> <base> <wt_path> <existing> <files_copied>
#                                    (legacy; kept for backwards compat — prefer
#                                    post-enter)
#
# Convention:
#   - structured "KEY=value" output goes to stdout (LLM parses)
#   - human diagnostics go to stderr (user sees, LLM ignores)
#   - exit 0 on success, 1 on git failure, 2 on usage error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
usage:
  $(basename "$0") candidates
  $(basename "$0") prepare <name> [base]
  $(basename "$0") post-enter [--mark]
  $(basename "$0") session-unmark
EOF
  exit 2
}

cmd_candidates() {
  wt_require_git || exit 1
  local MAIN CURRENT_WT
  MAIN=$(wt_main_dir)
  CURRENT_WT=
  if wt_in_worktree; then
    CURRENT_WT=$(git rev-parse --show-toplevel)
  fi

  # Header lines for the markdown to detect session state without extra bash calls.
  if [[ -n "$CURRENT_WT" ]]; then
    echo "IN_WORKTREE=yes"
  else
    echo "IN_WORKTREE=no"
  fi
  if wt_session_active; then
    echo "ACTIVE_SESSION=yes"
  else
    echo "ACTIVE_SESSION=no"
  fi

  # Body: <ts>\t<path>\t<branch>\t<dirty>\t<ahead>/<behind>\t<last_commit>
  # Sorted by last-commit timestamp, descending.
  git -C "$MAIN" worktree list --porcelain | awk '
    /^worktree / { p = $2; next }
    /^branch refs\/heads\// { sub("refs/heads/", "", $2); print p "\t" $2 }
  ' | while IFS=$'\t' read -r p b; do
    [[ "$p" == "$MAIN" ]] && continue
    [[ -n "$CURRENT_WT" && "$p" == "$CURRENT_WT" ]] && continue
    local ts dirty ab behind ahead last
    ts=$(git -C "$p" log -1 --format=%ct 2>/dev/null || echo 0)
    dirty=clean
    [[ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]] && dirty=dirty
    if ab=$(git -C "$p" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
      behind=$(echo "$ab" | awk '{print $1}')
      ahead=$(echo "$ab" | awk '{print $2}')
    else
      behind=0; ahead=0
    fi
    last=$(git -C "$p" log -1 --format=%cr 2>/dev/null || echo unknown)
    printf '%s\t%s\t%s\t%s\t%s/%s\t%s\n' "$ts" "$p" "$b" "$dirty" "$ahead" "$behind" "$last"
  done | sort -t$'\t' -k1,1nr
}

cmd_prepare() {
  local name="${1:-}" base_arg="${2:-}"
  [[ -z "$name" ]] && { echo "ERROR: prepare requires a branch name" >&2; exit 2; }

  wt_require_git || exit 1

  if ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
    echo "ERROR: invalid branch name: $name" >&2
    exit 1
  fi

  local MAIN BASE WT_PATH IN_WT
  MAIN=$(wt_main_dir)
  BASE="${base_arg:-$(wt_default_branch)}"
  WT_PATH=$(wt_path "$name")
  IN_WT=no
  wt_in_worktree && IN_WT=yes

  # Are we already in the target worktree? If so, both ExitWorktree and
  # EnterWorktree are no-ops / errors — the caller should skip them.
  CURRENT=no
  if [[ "$IN_WT" == "yes" ]] && [[ "$(git rev-parse --show-toplevel 2>/dev/null)" == "$WT_PATH" ]]; then
    CURRENT=yes
  fi

  # Does a prior EnterWorktree session need releasing first? See lib.sh
  # wt_session_* — marker is written by post-enter --mark, cleared by end.sh
  # teardown. wt_session_active also verifies CWD is inside the recorded
  # worktree, so a stale marker (e.g., CC session was reset but file remains)
  # gets caught here. If we detect a stale marker, clear it proactively.
  local ACTIVE_SESSION=no
  if wt_session_active; then
    ACTIVE_SESSION=yes
  else
    [[ -f "$(wt_session_marker)" ]] && wt_session_unmark
  fi

  # Emit core paths early so the caller can use them on partial failure.
  printf 'NAME=%s\n' "$name"
  printf 'BASE=%s\n' "$BASE"
  printf 'MAIN=%s\n' "$MAIN"
  printf 'WT_PATH=%s\n' "$WT_PATH"
  printf 'IN_WORKTREE=%s\n' "$IN_WT"
  printf 'CURRENT=%s\n' "$CURRENT"
  printf 'ACTIVE_SESSION=%s\n' "$ACTIVE_SESSION"

  # Fetch base (warn-only on failure; offline is OK).
  if ! git -C "$MAIN" fetch origin "$BASE" 2>/dev/null; then
    echo "WARNING: fetch of $BASE failed; continuing with local state" >&2
  fi

  # Already exists? Enter via path; no creation needed.
  if git -C "$MAIN" worktree list --porcelain | awk '/^worktree / {print $2}' | grep -Fxq "$WT_PATH"; then
    printf 'EXISTING=yes\n'
    printf 'FILES_COPIED=skipped\n'
    printf 'STATUS=ok\n'
    return 0
  fi
  printf 'EXISTING=no\n'

  local state
  state=$(wt_branch_state "$name")
  printf 'BRANCH_STATE=%s\n' "$state"

  case "$state" in
    none)
      # --no-track: don't inherit origin/$BASE as upstream. The new branch should
      # have no upstream until `git push -u origin <branch>` sets it later.
      git -C "$MAIN" worktree add -q --no-track -b "$name" "$WT_PATH" "origin/$BASE" >&2 || {
        printf 'STATUS=failed-create\n'; exit 1
      }
      ;;
    local)
      git -C "$MAIN" worktree add -q "$WT_PATH" "$name" >&2 || {
        printf 'STATUS=failed-create\n'; exit 1
      }
      ;;
    remote)
      git -C "$MAIN" fetch origin "$name" 2>/dev/null >&2 || true
      git -C "$MAIN" worktree add -q "$WT_PATH" -b "$name" "origin/$name" >&2 || {
        printf 'STATUS=failed-create\n'; exit 1
      }
      ;;
    both)
      if git -C "$MAIN" merge-base --is-ancestor "$name" "origin/$name" 2>/dev/null \
         && [[ "$(git -C "$MAIN" rev-parse "$name")" != "$(git -C "$MAIN" rev-parse "origin/$name")" ]]; then
        git -C "$MAIN" fetch origin "$name:$name" 2>/dev/null >&2 || true
      fi
      git -C "$MAIN" worktree add -q "$WT_PATH" "$name" >&2 || {
        printf 'STATUS=failed-create\n'; exit 1
      }
      ;;
    *)
      printf 'STATUS=failed-state-unknown\n'; exit 1 ;;
  esac

  # Copy gitignored root files. Helper script prints "  copied: X" lines for each file.
  local copied=0
  if [[ -x "$SCRIPT_DIR/copy-untracked.sh" ]]; then
    local copy_output
    copy_output=$("$SCRIPT_DIR/copy-untracked.sh" "$MAIN" "$WT_PATH" 2>&1)
    copied=$(echo "$copy_output" | grep -c '^  copied:' || true)
  fi
  printf 'FILES_COPIED=%d\n' "$copied"
  printf 'STATUS=ok\n'
}

cmd_post_enter() {
  # Run AFTER EnterWorktree has switched the session into the worktree
  # (or, in the CURRENT=yes short-circuit, with no preceding tool call).
  # Self-contained: infers branch, base, and path from current git state.
  #
  # Optional --mark flag: record the EnterWorktree session as active. The
  # caller passes --mark only when an EnterWorktree call actually ran
  # (i.e., not in the CURRENT=yes short-circuit, where the LLM skipped
  # the call because we were already in the target worktree).
  #
  # Output contract: structured KEY=value pairs on stdout only — no banner
  # text from the script. The user-facing "Worktree ready" banner is composed
  # by the LLM in its own assistant reply (per commands/start.md step 8), so
  # the trailing "/rename <branch>" line appears in the assistant's typed
  # message rather than inside a tool-result block — that's the format
  # Claude Code's terminal CLI scans for slash-command autocomplete.
  local mark=0
  if [[ "${1:-}" == "--mark" ]]; then
    mark=1
    shift
  fi

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: /work:start post-enter must run inside a git worktree" >&2
    exit 1
  fi

  if (( mark )); then
    wt_session_mark
  fi
  local wt_path branch base
  wt_path=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  branch=$(git -C "$wt_path" symbolic-ref --short HEAD 2>/dev/null || echo "?")
  # Prefer the branch's configured upstream merge ref; fall back to the repo
  # default branch (works for --no-track new branches that have no upstream yet).
  base=$(git -C "$wt_path" config "branch.$branch.merge" 2>/dev/null | sed 's|^refs/heads/||')
  if [[ -z "$base" ]]; then
    base=$(cd "$wt_path" && wt_default_branch)
  fi

  printf 'BRANCH=%s\n' "$branch"
  printf 'BASE=%s\n'   "$base"
  printf 'WT_PATH=%s\n' "$wt_path"
}

cmd_session_unmark() {
  wt_session_unmark
}

case "${1:-}" in
  candidates)     shift; cmd_candidates "$@" ;;
  prepare)        shift; cmd_prepare "$@" ;;
  post-enter)     shift; cmd_post_enter "$@" ;;
  session-unmark) shift; cmd_session_unmark "$@" ;;
  ""|-h|--help) usage ;;
  *)           echo "unknown subcommand: $1" >&2; usage ;;
esac

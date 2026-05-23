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
  $(basename "$0") post-enter
  $(basename "$0") summary <name> <base> <wt_path> <existing> <files_copied>
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

  # Header line for the markdown to detect session state without an extra bash call.
  if [[ -n "$CURRENT_WT" ]]; then
    echo "IN_WORKTREE=yes"
  else
    echo "IN_WORKTREE=no"
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

  # Emit core paths early so the caller can use them on partial failure.
  printf 'NAME=%s\n' "$name"
  printf 'BASE=%s\n' "$BASE"
  printf 'MAIN=%s\n' "$MAIN"
  printf 'WT_PATH=%s\n' "$WT_PATH"
  printf 'IN_WORKTREE=%s\n' "$IN_WT"

  # Fetch base (warn-only on failure; offline is OK).
  if ! git -C "$MAIN" fetch origin "$BASE" 2>/dev/null; then
    echo "WARNING: fetch of $BASE failed; continuing with local state" >&2
  fi

  # Already exists? Enter via path; no creation needed.
  if git -C "$MAIN" worktree list --porcelain | awk '/^worktree / {print $2}' | grep -Fxq "$WT_PATH"; then
    printf 'EXISTING=yes\n'
    printf 'FILES_COPIED=skipped\n'
    printf 'STATUS=ok\n'
    echo "Worktree already exists at $WT_PATH; will enter it." >&2
    return 0
  fi
  printf 'EXISTING=no\n'

  local state
  state=$(wt_branch_state "$name")
  printf 'BRANCH_STATE=%s\n' "$state"

  case "$state" in
    none)
      echo "Creating new branch '$name' from origin/$BASE..." >&2
      # --no-track: don't inherit origin/$BASE as upstream. The new branch should
      # have no upstream until `git push -u origin <branch>` sets it later.
      git -C "$MAIN" worktree add --no-track -b "$name" "$WT_PATH" "origin/$BASE" >&2 || {
        printf 'STATUS=failed-create\n'; exit 1
      }
      ;;
    local)
      echo "Branch '$name' already existed locally; reusing it." >&2
      git -C "$MAIN" worktree add "$WT_PATH" "$name" >&2 || {
        printf 'STATUS=failed-create\n'; exit 1
      }
      ;;
    remote)
      echo "Branch '$name' already existed on origin; checking it out." >&2
      git -C "$MAIN" fetch origin "$name" 2>/dev/null >&2 || true
      git -C "$MAIN" worktree add "$WT_PATH" -b "$name" "origin/$name" >&2 || {
        printf 'STATUS=failed-create\n'; exit 1
      }
      ;;
    both)
      echo "Branch '$name' existed both locally and on origin; using local." >&2
      if git -C "$MAIN" merge-base --is-ancestor "$name" "origin/$name" 2>/dev/null \
         && [[ "$(git -C "$MAIN" rev-parse "$name")" != "$(git -C "$MAIN" rev-parse "origin/$name")" ]]; then
        echo "  fast-forwarding local '$name' to match origin..." >&2
        git -C "$MAIN" fetch origin "$name:$name" 2>/dev/null >&2 || true
      fi
      git -C "$MAIN" worktree add "$WT_PATH" "$name" >&2 || {
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
    echo "$copy_output" >&2
  fi
  printf 'FILES_COPIED=%d\n' "$copied"
  printf 'STATUS=ok\n'
}

_print_ready_banner() {
  # Args: <branch> <base> <wt_path> [files_copied_note]
  # files_copied_note is rendered as the "files copied:" value; pass empty to
  # omit the line entirely.
  local branch="${1:-?}" base="${2:-?}" wt_path="${3:-?}" files_note="${4:-}"
  local no_rename="${CLAUDE_TREE_NO_RENAME:-}"

  echo "─────────────────────────────────────────"
  echo " Worktree ready"
  echo "─────────────────────────────────────────"
  printf 'branch:        %s\n' "$branch"
  printf 'base:          %s\n' "$base"
  printf 'path:          %s\n' "$wt_path"
  if [[ -n "$files_note" ]]; then
    printf 'files copied:  %s\n' "$files_note"
  fi
  echo ""
  echo "Session is now switched to the worktree."

  if [[ "$no_rename" != "1" ]]; then
    echo ""
    echo "To rename this session to match the branch, type:"
    printf '  /rename %s\n' "$branch"
    echo "(Set CLAUDE_TREE_NO_RENAME=1 in your shell to suppress this hint.)"
  fi

  echo ""
  echo "Next: /work:status, /work:sync, /work:end"
  echo "─────────────────────────────────────────"
}

cmd_post_enter() {
  # Run AFTER EnterWorktree has switched the session into the worktree.
  # Self-contained: infers branch, base, and path from current git state, so
  # the markdown only has to make one zero-arg call.
  #
  # Output contract:
  #   stdout, first line: BRANCH=<branch>     (structured — markdown reads this
  #                                            to compose the rename suggestion
  #                                            in the LLM's own assistant text,
  #                                            which is what triggers CC's
  #                                            input-field prefill — printing
  #                                            the slash command from inside a
  #                                            tool result does NOT trigger it)
  #   stdout, second line: RENAME_BRANCH=<branch>|<empty>
  #                                           (<empty> means CLAUDE_TREE_NO_RENAME=1
  #                                            was set; LLM must skip the hint)
  #   stderr: the human-readable "Worktree ready" banner
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: /work:start post-enter must run inside a git worktree" >&2
    exit 1
  fi
  local wt_path branch base no_rename rename_hint
  wt_path=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  branch=$(git -C "$wt_path" symbolic-ref --short HEAD 2>/dev/null || echo "?")
  # Prefer the branch's configured upstream merge ref; fall back to the repo
  # default branch (works for --no-track new branches that have no upstream yet).
  base=$(git -C "$wt_path" config "branch.$branch.merge" 2>/dev/null | sed 's|^refs/heads/||')
  if [[ -z "$base" ]]; then
    base=$(cd "$wt_path" && wt_default_branch)
  fi

  no_rename="${CLAUDE_TREE_NO_RENAME:-}"
  rename_hint="$branch"
  [[ "$no_rename" == "1" ]] && rename_hint=""

  # Structured markers for the markdown / LLM to parse.
  printf 'BRANCH=%s\n' "$branch"
  printf 'RENAME_BRANCH=%s\n' "$rename_hint"

  # Human-readable banner on stderr (no rename text — that comes from the LLM's
  # own assistant message so the CC input-field suggestion fires).
  {
    echo "─────────────────────────────────────────"
    echo " Worktree ready"
    echo "─────────────────────────────────────────"
    printf 'branch:        %s\n' "$branch"
    printf 'base:          %s\n' "$base"
    printf 'path:          %s\n' "$wt_path"
    echo ""
    echo "Session is now switched to the worktree."
    echo ""
    echo "Next: /work:status, /work:sync, /work:end"
    echo "─────────────────────────────────────────"
  } >&2
}

cmd_summary() {
  # Legacy entry: keeps backwards compatibility with the previous markdown
  # contract. Prefer post-enter for new callers.
  local name="${1:-?}" base="${2:-?}" wt_path="${3:-?}" existing="${4:-no}" files_copied="${5:-0}"
  local files_note
  if [[ "$existing" == "yes" ]]; then
    files_note="(skipped — entering existing)"
  else
    files_note="$files_copied"
  fi
  _print_ready_banner "$name" "$base" "$wt_path" "$files_note"
}

case "${1:-}" in
  candidates)  shift; cmd_candidates "$@" ;;
  prepare)     shift; cmd_prepare "$@" ;;
  post-enter)  shift; cmd_post_enter "$@" ;;
  summary)     shift; cmd_summary "$@" ;;
  ""|-h|--help) usage ;;
  *)           echo "unknown subcommand: $1" >&2; usage ;;
esac

#!/usr/bin/env bash
# Shared helpers for the `work` plugin.
# Source this from command bash blocks or other scripts:
#   . "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"

wt_require_git() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: not inside a git repository" >&2
    return 1
  fi
}

wt_main_dir() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$common"
}

wt_in_worktree() {
  local gd cd_
  gd=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  cd_=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ "$gd" != "$cd_" ]]
}

wt_default_branch() {
  local b
  b=$(git symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null | sed 's@^origin/@@')
  if [[ -n "${b:-}" ]]; then
    echo "$b"
    return 0
  fi
  for c in main master develop trunk; do
    if git rev-parse --verify "refs/heads/$c" >/dev/null 2>&1 \
       || git rev-parse --verify "refs/remotes/origin/$c" >/dev/null 2>&1; then
      echo "$c"
      return 0
    fi
  done
  echo "main"
}

wt_path() {
  echo "$(wt_main_dir)/.worktrees/$1"
}

wt_branch_state() {
  local name="$1"
  local has_local=0 has_remote=0
  git show-ref --verify --quiet "refs/heads/$name" && has_local=1
  git show-ref --verify --quiet "refs/remotes/origin/$name" && has_remote=1
  if (( has_local && has_remote )); then
    echo "both"
  elif (( has_local )); then
    echo "local"
  elif (( has_remote )); then
    echo "remote"
  else
    echo "none"
  fi
}

wt_has_gh() {
  command -v gh >/dev/null 2>&1
}

wt_pr_for() {
  local branch="$1"
  wt_has_gh || { echo ""; return 0; }
  gh pr view "$branch" --json number,state,url 2>/dev/null
}

wt_dirty() {
  [[ -n "$(git status --porcelain 2>/dev/null)" ]]
}

wt_unpushed_count() {
  if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    echo "no-upstream"
    return 0
  fi
  git rev-list '@{u}..HEAD' --count 2>/dev/null
}

wt_ahead_behind() {
  if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    echo "no-upstream"
    return 0
  fi
  local counts
  counts=$(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null) || { echo "0 0"; return 0; }
  echo "$counts"
}

# Per-CC-session marker indicating whether an EnterWorktree session is
# currently active. Lets /work:start's markdown call ExitWorktree only when
# there is something to release — avoiding both the "Error: No-op: no active
# session" UI line (when nothing is active) and the "Error: Already in a
# worktree session" UI line (when something is, and we skipped the release).
#
# Marker lifecycle:
#   - written by start.sh post-enter (after EnterWorktree has succeeded)
#   - cleared by end.sh teardown (after the LLM has called ExitWorktree)

wt_session_id() {
  # Stable identifier for the current Claude Code session. Walks up the
  # process tree from this script and returns the PID of the closest
  # 'claude' ancestor. Falls back to the parent of $PPID (the shell spawned
  # by CC's Bash tool — its parent is the CC process in the standard model).
  local pid=$PPID
  local hops=0
  while [[ "$pid" -gt 1 && "$hops" -lt 30 ]]; do
    local pname
    pname=$(ps -o comm= -p "$pid" 2>/dev/null | awk '{print $NF}')
    pname=${pname##*/}
    if [[ "$pname" == "claude" ]]; then
      echo "$pid"
      return 0
    fi
    local parent
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$parent" || "$parent" == "0" ]] && break
    pid="$parent"
    hops=$((hops + 1))
  done
  ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' '
}

wt_session_marker() {
  printf '%s/claude-work-session-%s.active\n' "${TMPDIR:-/tmp}" "$(wt_session_id)"
}

wt_session_active() {
  # Returns 0 (truthy in shell) if a prior EnterWorktree session is likely
  # still active. We require BOTH the marker file to exist AND the current
  # working directory to be inside the marker's recorded worktree path —
  # to catch cases where the marker has outlived CC's internal session
  # state (e.g., CWD has been reset back to the launch directory).
  local marker
  marker="$(wt_session_marker)"
  [[ -f "$marker" ]] || return 1
  local recorded
  recorded=$(head -n1 "$marker" 2>/dev/null)
  [[ -z "$recorded" ]] && return 1
  local cwd
  cwd=$(pwd -P 2>/dev/null) || return 1
  [[ "$cwd" == "$recorded" || "$cwd" == "$recorded"/* ]]
}

wt_session_mark() {
  # Record the active worktree's root path so future calls can verify the
  # marker is still relevant. Called from post-enter with --mark, only when
  # EnterWorktree actually established a session in this CC run.
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  printf '%s\n' "$root" > "$(wt_session_marker)" 2>/dev/null || true
}

wt_session_unmark() {
  rm -f "$(wt_session_marker)" 2>/dev/null || true
}

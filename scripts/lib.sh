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

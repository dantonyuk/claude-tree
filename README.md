# claude-tree

A [Claude Code](https://claude.com/claude-code) plugin for **worktree-per-ticket** git workflows. One slash command spins up a worktree; one tears it down. Every Claude session automatically knows whether it's in the main checkout or in a worktree, so you don't have to re-explain context every time.

## Why

Switching with `git switch` clobbers your in-progress diff. `git stash` is fiddly. Doing it by hand — `git worktree add`, copy `.env`, install deps, remember to clean up — is repetitive and easy to forget.

This plugin codifies the pattern:

- `/work:start CORE-1234` — create or enter a worktree at `<repo>/.worktrees/CORE-1234`
- `/work:end` — handle uncommitted/unpushed/no-PR work, then remove the worktree (branch kept)
- `/work:list` — see every active worktree at a glance with PR status
- `/work:status` — detailed status for the current worktree
- `/work:sync` — rebase the current worktree against its base branch
- `/work:clean` — bulk-remove worktrees whose PRs are merged or closed

A **SessionStart hook** runs in every Claude session: in a worktree it prints branch/base/ahead-behind/PR info; in the main checkout it lists active worktrees. The assistant gets this context for free.

## Install

### From local path (during development or for personal use)

```bash
# In any Claude Code session:
/plugin marketplace add /Users/you/Projects/claude-tree
/plugin install work@claude-tree
```

To pick up local changes after editing the plugin:

```bash
/plugin marketplace update claude-tree
```

### From GitHub

```bash
/plugin marketplace add dantonyuk/claude-tree
/plugin install work@claude-tree
```

## Commands

### `/work:start [branch] [base]`

Create a worktree at `<main>/.worktrees/<branch>` for the named branch, or enter it if it already exists.

- `<branch>` — used as-is for the branch name. Examples: `CORE-1234`, `feature/oauth`, `fix-typo`.
- `<base>` — optional. Defaults to the repo's default branch (detected from `origin/HEAD`). Fetched from the remote before the worktree is created.

**No-argument mode:** running `/work:start` with no arguments opens an interactive picker of existing worktrees so you can switch between them quickly. If there are no worktrees yet, it prints a usage hint instead.

If the branch already exists (locally, remotely, or both), it's checked out and you get a notice. Gitignored root files (`.env`, `.env.local`, `.npmrc`, etc.) are copied from the main checkout into the new worktree — directories like `node_modules/` are skipped.

After creating or detecting the worktree, the command invokes the built-in `EnterWorktree` tool with the worktree's absolute path. This properly switches the Claude Code session's working directory (clearing CWD-dependent caches), so `Read`, `Glob`, and `Bash` all see the worktree as the new root. If the session was already inside another managed worktree, `ExitWorktree({ action: "keep" })` is called first to leave it intact before entering the new one — so switching between worktrees in the same session is supported.

At the end of `/work:start`, the command prints a suggestion to rename the session:

```
To rename this session to match the branch, type:
  /rename CORE-1234
```

To suppress that hint, set `CLAUDE_TREE_NO_RENAME=1` in your shell (or via Bash inside the session). The rename itself still has to be typed by you — slash commands can only be issued by user input, not by an agent.

### `/work:end`

Tear down the current worktree.

Detects:
- uncommitted changes
- unpushed commits
- whether a PR exists for the branch

…and presents a single combined prompt with grouped options (commit+push+PR, just push, remove anyway, cancel, etc.). On approval, runs the chosen steps, then `cd`s back to the main checkout and `git worktree remove`s the path. The branch is kept.

### `/work:list`

Read-only summary of every worktree in the repo: branch, dirty marker, ahead/behind vs upstream, PR state (open / merged / closed / none), last commit time.

### `/work:status`

Detailed info for the current worktree: branch, base, ahead/behind upstream, behind base, dirty files, commits ahead of base, PR link.

### `/work:sync`

Fetch and rebase the current worktree against its base branch. Offers a stash-rebase-pop flow if the working tree is dirty. Stops on conflict and tells you what to do next.

### `/work:clean`

Find worktrees whose PR is merged or closed, present them as a multi-select, and remove the selected ones. Refuses to discard dirty or unpushed work unless you explicitly opt in. Branches are never deleted.

## How it works

```
your-repo/                       (main checkout, has the .git dir)
├── src/
├── package.json
├── .env                         (gitignored)
├── .worktrees/                  (created on first /work:start)
│   ├── CORE-1234/
│   │   ├── src/                 (independent working tree)
│   │   ├── package.json
│   │   └── .env                 (copied from main)
│   └── CORE-5678/
└── …
```

Each worktree is a full checkout sharing the same `.git` directory. Switching between them is `cd`, not `git switch` — no stashing, no merge churn.

## Requirements

- **git ≥ 2.5** (worktrees)
- **bash** (POSIX shell, scripts use bash-specific features)
- **gh CLI** (optional) — required for PR-related features (`/work:clean`, PR display in `/work:list` and `/work:end`). Without it, those features degrade gracefully.

## Limitations / known issues

- **Session rename:** `/work:start` cannot rename the session for you — slash commands are user-input only. It prints a suggestion (`/rename <branch>`) for you to type. Disable the suggestion with `CLAUDE_TREE_NO_RENAME=1`.
- **Plugin command namespace:** Claude Code requires plugin commands to use the `/<plugin>:<command>` form. There's no bare `/start` shortcut for `/work:start` — typing `/work:` will autocomplete all six subcommands, which is the intended discovery path.
- **Branch naming:** Names are validated via `git check-ref-format --branch` before any mutation. Special characters or reserved names will be rejected before the worktree is created.
- **`/work:end` is cross-session:** unlike the built-in `ExitWorktree` (which only handles worktrees created by `EnterWorktree` in the same session), `/work:end` works on any worktree under `.worktrees/` — including ones created in a previous session. It uses `git worktree remove` directly.

## License

MIT — see `LICENSE`.

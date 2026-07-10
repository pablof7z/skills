# WorktreeGuard Codex

Codex plugin package for the WorktreeGuard product spec that prompted this
repository addition.

This package installs Codex lifecycle hooks and a bundled local `wtg` command
for protection, status, hook handling, and base-access approval requests. Hooks
prefer the stable `~/.local/bin/wtg-hook-codex` entrypoint when it exists, then
fall back to the hook bundled in the installed plugin cache. The bundled hook
uses the bundled WorktreeGuard-lite command by default; set `WTG_BIN` to
delegate hook events to another WorktreeGuard command. Git main worktrees are
protected by default; linked Git worktrees are allowed mutation targets, and
non-Git directories are ignored.

```bash
<plugin-root>/bin/wtg status --repo <repo>
<plugin-root>/bin/wtg request-base-access --repo <repo> --reason "<reason>"
<plugin-root>/bin/wtg actions --tail 50
<plugin-root>/bin/wtg actions -f --color always
<plugin-root>/bin/wtg denials --tail 50
<plugin-root>/bin/wtg denials -f --color always
```

The full WorktreeGuard CLI and daemon should eventually own durable policy,
grants, audit logs, and rollback behavior. The bundled command covers the first
testable Codex workflow: protect Git main worktrees by default, deny mutating
Codex tool calls there, allow shell commands by default unless they match known
mutating commands or write redirection, allow Git commands by default unless
they mutate the protected checkout/index/local branch state, recognize normal
Git worktree use, track Codex's effective session cwd after worktree entry, and
show a macOS approval prompt for temporary base checkout access. Denied actions
are appended to `~/worktreeguard-denied-actions.jsonl`.

## Install From This Repo

From the repository root:

```bash
codex plugin marketplace add "$PWD"
codex plugin add worktreeguard-codex@skills-local
```

Start a new Codex session after installation so the hook package is loaded.

## Requirements

- `git` must be available.
- Git main worktrees are protected by default.
- `protect` is still available when you want to record explicit local state; it
  requires a clean base checkout.
- The bundled command stores local state in
  `~/.local/state/worktreeguard/lite-state.json`.
- All checked `PreToolUse` and `PermissionRequest` decisions are logged to
  `~/worktreeguard-actions.jsonl` by default, including allowed commands,
  denials, grant-based allows, and branch repair attempts. Set
  `WTG_ACTION_LOG_FILE` to use a different JSONL file.
- Denied actions are logged to `~/worktreeguard-denied-actions.jsonl` by
  default. Set `WTG_DENY_LOG_FILE` to use a different JSONL file. Hook process
  crashes, including shell `127` command-not-found failures before `wtg` starts,
  are not policy denials and will not appear in this log.
- `wtg doctor` reports whether the stable `~/.local/bin/wtg-hook-codex` shim is
  executable. That shim keeps active Codex sessions from depending on an old
  plugin-cache path after reinstalling or bumping the local plugin version.
- Use `wtg denials --tail 50` to summarize and inspect recent denials.
- Use `wtg actions --tail 50` to summarize and inspect recent checked actions.
- Use `wtg actions -f` to follow allowed, denied, and repair decisions live.
- Use `wtg denials -f` to follow new denials live. Human output is colorized
  automatically on terminals; use `--color always` or `--no-color` to override.

## Hook Coverage

- `SessionStart`: tells Codex whether the current repo is protected and reminds
  it to do mutating work from a Git worktree.
- `PreToolUse`: checks Bash, shell, patch, write, edit, and MCP tool attempts.
- `PermissionRequest`: allows a valid local grant or denies protected-base
  mutations with Git-native worktree guidance.
- `PostToolUse`: records effective session cwd evidence from `pwd` and
  successful native `git worktree add` commands.
- `Stop`: clears tracked session cwd state.

## Current Scope

This is still not the full WorktreeGuard Rust workspace. The full product still
needs `wtgd`, the Rust policy engine, SQLite state, and watcher rollback.
The bundled hook does include watcher-lite branch repair for protected base
checkouts: on each hook check, it restores a clean protected base checkout to
the repository default branch if the base drifted to another branch. It logs
repair failures instead of force-switching over dirty state.

# WorktreeGuard Codex

Codex plugin package for the WorktreeGuard product spec that prompted this
repository addition.

This package installs Codex lifecycle hooks and a bundled local `wtg` command
for protection, status, hook handling, and base-access approval requests.
When a real WorktreeGuard CLI is available on `PATH`, the hook delegates to it.
Otherwise, the bundled WorktreeGuard-lite command provides enough behavior to
test the base-checkout guardrail immediately:

```bash
<plugin-root>/bin/wtg protect --repo <repo>
<plugin-root>/bin/wtg request-base-access --repo <repo> --reason "<reason>"
```

The full WorktreeGuard CLI and daemon should eventually own durable policy,
grants, audit logs, and rollback behavior. The bundled command covers the first
testable Codex workflow: protect a clean base checkout, deny mutating Codex tool
calls there, allow read-only inspection, recognize normal Git worktree use, and
show a macOS approval prompt for temporary base checkout access.

## Install From This Repo

From the repository root:

```bash
codex plugin marketplace add "$PWD"
codex plugin add worktreeguard-codex@skills-local
```

Start a new Codex session after installation so the hook package is loaded.

## Requirements

- `git` must be available.
- A base checkout must be clean before `protect` will register it.
- The bundled command stores local state in
  `~/.local/state/worktreeguard/lite-state.json`.

## Hook Coverage

- `SessionStart`: tells Codex whether the current repo is protected and reminds
  it to do mutating work from a Git worktree.
- `PreToolUse`: checks Bash, shell, patch, write, edit, and MCP tool attempts.
- `PermissionRequest`: allows a valid local grant or denies protected-base
  mutations with Git-native worktree guidance.
- `PostToolUse`: reserved for the full WorktreeGuard daemon.
- `Stop`: reserved for the full WorktreeGuard daemon.

## Current Scope

This is still not the full WorktreeGuard Rust workspace. The full product still
needs `wtgd`, the Rust policy engine, SQLite state, and watcher rollback.

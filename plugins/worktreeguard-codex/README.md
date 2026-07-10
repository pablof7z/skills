# WorktreeGuard Codex

Codex plugin package for the WorktreeGuard product spec that prompted this
repository addition.

This package installs Codex lifecycle hooks that call:

```bash
wtg hook codex <event>
```

The WorktreeGuard CLI and daemon own policy, repo registration, grants, worktree
creation, audit logs, and rollback behavior. This plugin is the Codex adapter:
it translates Codex hook entrypoints into WorktreeGuard hook calls and renders
Codex-compatible denials when the local fallback can identify an explicitly
protected base checkout.

## Install From This Repo

From the repository root:

```bash
codex plugin marketplace add "$PWD"
codex plugin add worktreeguard-codex@skills-local
```

Start a new Codex session after installation so the hook package is loaded.

## Requirements

- `wtg` must be on `PATH` for full policy enforcement.
- Protected repositories should be registered with WorktreeGuard.
- The fallback only applies when `WTG_PROTECTED_BASE`, `WTG_BASE_PATH`, or a
  base checkout `.wtg.toml` marker makes the protected base path explicit.

## Hook Coverage

- `SessionStart`: registers the session or adds setup context when `wtg` is
  unavailable.
- `PreToolUse`: checks Bash, shell, patch, write, edit, and MCP tool attempts.
- `PermissionRequest`: asks WorktreeGuard whether a grant covers the requested
  operation.
- `PostToolUse`: delegates result logging to WorktreeGuard.
- `Stop`: delegates session shutdown state to WorktreeGuard.

## Current Scope

This is the Codex adapter package, not the full WorktreeGuard Rust workspace.
The full product still needs the `wtg` CLI, `wtgd` daemon, policy engine,
SQLite state, watcher, and human approval UI described in the product spec.

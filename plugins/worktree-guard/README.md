# WorktreeGuard

Multi-harness plugin package for the WorktreeGuard product spec that prompted
this repository addition. It supports both **Codex** and **Claude Code** from
one shared install.

This package installs harness lifecycle hooks and a bundled local `wtg`
command for protection, status, hook handling, and base-access approval
requests. Hooks prefer the stable `~/.local/bin/wtg-hook-<harness>` entrypoint
when it exists, then fall back to the hook bundled in the installed plugin
cache. The bundled hook uses the bundled WorktreeGuard-lite command by
default; set `WTG_BIN` to delegate hook events to another WorktreeGuard
command. Git main worktrees are protected by default; linked Git worktrees are
allowed mutation targets, and non-Git directories are ignored.

```bash
<plugin-root>/bin/wtg status --repo <repo>
<plugin-root>/bin/wtg request-base-access --repo <repo> --reason "<reason>"
<plugin-root>/bin/wtg actions --tail 50
<plugin-root>/bin/wtg actions -f --color always
<plugin-root>/bin/wtg denials --tail 50
<plugin-root>/bin/wtg denials -f --color always
python3 <plugin-root>/scripts/probe_worktreeguard_lite.py
```

The full WorktreeGuard CLI and daemon should eventually own durable policy,
grants, audit logs, and rollback behavior. The bundled command covers the
first testable workflow: protect Git main worktrees by default, deny direct
agent write tools there, allow non-Git shell commands by default, and deny
only explicitly dangerous Git subcommands such as `reset`, `checkout`,
`switch`, `clean`, `restore`, and `rebase`. Normal Git commands, including
`worktree`, `fetch`, `pull`, `merge`, `add`, and `commit`, are allowed by
default. The hook tracks the agent's effective session cwd after worktree
entry, honors simple shell `cd <path> && git ...` cwd changes, and shows a
macOS approval prompt for temporary base checkout access. Denied actions are
appended to `~/worktreeguard-denied-actions.jsonl`.
Agent write tools are path-based: known targets outside protected main
worktrees are allowed even when the session cwd is protected, while known
targets inside a protected main worktree are denied.

## Architecture

The policy engine (`lib/worktreeguard_lite.py`) and the `wtg` CLI (`bin/wtg`)
are entirely harness-agnostic — the same code decides allow/deny for both
Codex and Claude Code. Only the thin pieces that differ per harness are kept
separate:

```
plugins/worktree-guard/
|-- .codex-plugin/plugin.json    # Codex plugin manifest
|-- .claude-plugin/plugin.json   # Claude Code plugin manifest
|-- hooks/hooks.json             # shared hook registration (harness auto-detected at runtime)
|-- bin/
|   |-- wtg                      # shared CLI / policy engine entrypoint
|   |-- wtg-hook-codex           # Codex hook shim -> `wtg hook codex <event>`
|   `-- wtg-hook-claude          # Claude Code hook shim -> `wtg hook claude <event>`
|-- lib/worktreeguard_lite.py    # shared policy engine, state, logging
`-- scripts/probe_worktreeguard_lite.py  # regression probe, runs both harnesses
```

`hooks/hooks.json` is installed once and read by whichever harness loads the
plugin. Each hook command checks `$CLAUDE_PLUGIN_ROOT` first (set by Claude
Code) and falls back to `$PLUGIN_ROOT` (set by Codex) to pick the harness and
locate the plugin root, then dispatches to the matching `wtg-hook-<harness>`
shim. Both shims run through the same `wtg hook <harness> <event>` surface in
`worktreeguard_lite.py`, which handles `codex` and `claude` identically since
both harnesses use the same `PreToolUse` / `PermissionRequest` / `PostToolUse`
/ `SessionStart` / `Stop` hook event names and the same
`hookSpecificOutput` JSON shape.

## Install From This Repo

### Codex

From the repository root:

```bash
codex plugin marketplace add "$PWD"
codex plugin add worktree-guard@skills-local
```

Start a new Codex session after installation so the hook package is loaded.

### Claude Code

From the repository root:

```bash
claude plugin marketplace add "$PWD"
claude plugin install worktree-guard
```

Or for local iteration without a marketplace entry:

```bash
claude --plugin-dir plugins/worktree-guard
```

Start a new Claude Code session after installation so the hook package is
loaded.

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
- `wtg doctor` reports whether the stable `~/.local/bin/wtg-hook-codex` and
  `~/.local/bin/wtg-hook-claude` shims are executable. Those shims keep active
  sessions from depending on an old plugin-cache path after reinstalling or
  bumping the local plugin version.
- Use `wtg denials --tail 50` to summarize and inspect recent denials.
- Use `wtg actions --tail 50` to summarize and inspect recent checked actions.
- Use `wtg actions -f` to follow allowed, denied, and repair decisions live.
- Use `wtg denials -f` to follow new denials live. Human output is colorized
  automatically on terminals; use `--color always` or `--no-color` to override.
- Run `python3 scripts/probe_worktreeguard_lite.py` before reinstalling or
  changing the hook. It creates temporary Git repos and linked worktrees, calls
  the shared hook JSON surface directly for both the Codex and Claude Code
  harness dispatch paths, and verifies broad allow/deny behavior.

## Hook Coverage

- `SessionStart`: tells the agent whether the current repo is protected and
  reminds it to do mutating work from a Git worktree.
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

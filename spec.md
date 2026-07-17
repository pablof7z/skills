# WorktreeGuard Specification

## Purpose

WorktreeGuard prevents a coding agent from accidentally running a short list
of destructive or checkout-changing Git commands in a repository's base
checkout. It nudges the agent toward a linked worktree, where those commands
are allowed.

It is a convenience guardrail, not a security control. Simplicity and a low
false-positive rate matter more than adversarial completeness.

## Product boundary

There is one product named **WorktreeGuard**. Harness-specific shims for Codex
and Claude Code are adapters to the same product, not separate variants.

WorktreeGuard evaluates only Bash/Shell hook events. It does not inspect or
classify MCP calls, patches, edits, writes, notebook operations, or arbitrary
tool names.

WorktreeGuard does not provide remote approval, pairing, relays, signing,
daemons, human-endpoint integration, branch repair, filesystem rollback,
watchers, sandboxing, or session working-directory state.

## Policy

The blocked Git subcommands are exactly:

- `checkout`
- `clean`
- `rebase`
- `reset`
- `restore`
- `switch`

A command is denied only when all of the following are true:

1. The hook is `PreToolUse` or `PermissionRequest`.
2. The tool is Bash or Shell.
3. An ordinary direct shell invocation resolves to one of the six subcommands.
4. The invocation's effective Git working directory belongs to the repository's
   main/base worktree.
5. No active local override applies.

Every other operation is allowed, including:

- the six subcommands in a linked worktree;
- all Git commands not listed above, including `add`, `commit`, `fetch`,
  `merge`, `pull`, and `worktree`;
- all non-Git shell commands;
- all non-shell tools;
- malformed or unrecognized input.

The parser should understand common accidental forms such as a hook-supplied
working directory, `git -C <path> ...`, `git --work-tree <path> ...`, and a
simple `cd <path> && git ...` sequence. It need not defeat aliases, nested shell
evaluation, deliberate obfuscation, or other bypass attempts.

Repository discovery is live through Git. Main worktrees are guarded by
default; no explicit repository registration exists.

## Local override

`wtg request-base-access` may ask the local user for a short `once` or
`session` override through a macOS dialog. Tests may use
`WTG_APPROVAL_RESPONSE`. If the local dialog is unavailable or fails, the
request is denied. There is no remote fallback.

## State and diagnostics

Only active local overrides require durable state. They are stored at
`~/.local/state/worktreeguard/state.json` unless `WTG_STATE_FILE` overrides the
path.

Denied commands are logged to `~/worktreeguard-denied-actions.jsonl` unless
`WTG_DENY_LOG_FILE` overrides the path. Allowed actions are not logged.

`wtg status` and `wtg current` report live Git context. `wtg doctor` reports
Git, state, denial-log, and stable hook-shim paths. `wtg denials` inspects the
denial log.

## Hook behavior

The shared hook manifest installs only `PreToolUse` and `PermissionRequest`,
both with matcher `Bash|Shell`. It installs no other lifecycle hooks.

A denial uses the harness's normal hook decision JSON and exits successfully;
the hook decision, not the process exit status, carries allow/deny behavior.
Failures to parse payloads or discover repositories fail open.

## Acceptance tests

The regression probe must exercise both Codex and Claude dispatch paths and
prove:

- all six listed commands are denied in a base checkout;
- all six are allowed in linked worktrees;
- representative normal Git and non-Git commands are allowed in a base;
- `git -C`, hook workdir, and simple `cd && git` resolve the correct checkout;
- non-shell tool payloads are ignored even if invoked directly in a test;
- the hook manifest contains only policy events and matches only Bash/Shell;
- a local once override allows exactly one otherwise-blocked command;
- malformed input fails open;
- only denials are logged.

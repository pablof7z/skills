# WorktreeGuard

WorktreeGuard is a lightweight accident-prevention hook for Codex and Claude
Code. It has two narrow policies:

> In a Git repository's base checkout, block `git checkout`, `git clean`,
> `git rebase`, `git reset`, `git restore`, and `git switch`.
>
> Block ordinary native `apply_patch`, `Edit`, `Write`, `MultiEdit`, and
> `NotebookEdit` operations when their target is inside a base checkout.

That is the entire boundary. Those operations are allowed in linked worktrees.
Every other Git command, non-Git shell command, and MCP tool is outside
WorktreeGuard's policy.

WorktreeGuard is not a security boundary. It recognizes ordinary direct Git
invocations and the target paths provided by harness-native write tools. It
does not inspect shell commands for indirect file writes or attempt to stop a
malicious or deliberately obfuscated caller.

## Commands

```bash
<plugin-root>/bin/wtg status --repo <path>
<plugin-root>/bin/wtg current --repo <path>
<plugin-root>/bin/wtg request-base-access --repo <path> --reason "<reason>"
<plugin-root>/bin/wtg denials --tail 20
<plugin-root>/bin/wtg doctor
python3 <plugin-root>/scripts/probe_worktreeguard.py
```

`request-base-access` uses a local macOS dialog. There is no remote approval,
pairing, daemon, relay, MCP integration, automatic branch repair, session cwd
tracking, or full allow-action audit.

## Architecture

The shared `lib/worktreeguard/` package owns the policy and CLI. The Codex and
Claude shims only translate their hook entrypoints into the shared command.
`hooks/hooks.json` matches `Bash|Shell` and the five native write tool names for
`PreToolUse` and `PermissionRequest`. It installs no other lifecycle hooks.

All Git main worktrees are guarded by default. No repository registration or
protection database is required. Local grants are stored in
`~/.local/state/worktreeguard/state.json`; denials are appended to
`~/worktreeguard-denied-actions.jsonl`.

## Install

From this repository root:

```bash
codex plugin marketplace add "$PWD"
codex plugin add worktree-guard@skills-local

claude plugin marketplace add "$PWD"
claude plugin install worktree-guard@skills-local
```

Start a new harness session after installation so it loads the hook manifest.

# WorktreeGuard

WorktreeGuard is a lightweight accident-prevention hook for Codex and Claude
Code. It has two narrow policies:

> In a Git repository's base checkout, block `git checkout`, `git clean`,
> `git rebase`, `git reset`, `git restore`, and `git switch`.
>
> Recognize ordinary native `apply_patch`, `Edit`, `Write`, `MultiEdit`, and
> `NotebookEdit` operations when their target is inside a base checkout.

Both are blocked in a base checkout until the agent explicitly asks for access
with `wtg request-base-access`. A write never grants itself permission; only a
request does. Once a request is granted, that harness session may both edit
files and run the six Git commands in that base checkout until the grant
expires. Everything is always allowed in linked worktrees.

`auto-grant-edits` controls how a *request* is answered, not whether the guard
applies. With it on (the default), a request is granted immediately and you get
one macOS notification telling you it happened. With it off, the request puts a
macOS approval dialog in front of you first.

That is the entire boundary. Every other Git command, non-Git shell command,
and MCP tool is outside WorktreeGuard's policy.

WorktreeGuard is not a security boundary. It recognizes ordinary direct Git
invocations and the target paths provided by harness-native write tools. It
does not inspect shell commands for indirect file writes or attempt to stop a
malicious or deliberately obfuscated caller.

## Commands

```bash
<plugin-root>/bin/wtg status --repo <path>
<plugin-root>/bin/wtg current --repo <path>
<plugin-root>/bin/wtg request-base-access --repo <path> --reason "<reason>"
<plugin-root>/bin/wtg config auto-grant-edits [on|off]
<plugin-root>/bin/wtg denials --tail 20
<plugin-root>/bin/wtg doctor
python3 <plugin-root>/scripts/probe_worktreeguard.py
```

`request-base-access` is the only way to obtain a grant. It is auto-granted with
a notification when `auto-grant-edits` is on, and asks through a local macOS
dialog when it is off. There is no remote approval, pairing, daemon, relay, MCP
integration, automatic branch repair, session cwd tracking, or full allow-action
audit.

`config auto-grant-edits` prints the current preference when no value is
provided. `on` is the default.

## Architecture

The shared `lib/worktreeguard/` package owns the policy and CLI. The Codex and
Claude shims only translate their hook entrypoints into the shared command.
`hooks/hooks.json` matches `Bash|Shell` and the five native write tool names for
`PreToolUse` only. It installs no other lifecycle hooks. WorktreeGuard takes no
part in the harness's own permission system; base access is requested through
`wtg`, not through a Claude or Codex prompt.

All Git main worktrees are guarded by default. No repository registration or
protection database is required. Local grants are stored in
`~/.local/state/worktreeguard/state.json` alongside the auto-grant preference;
denials are appended to `~/worktreeguard-denied-actions.jsonl`. Notifications are
local, non-interactive, and best-effort; notification delivery failure does not
block the grant. On macOS, WorktreeGuard prefers `terminal-notifier` when it is
available so the title, status, and message appear directly in Notification
Center. It falls back to AppleScript when no native sender is installed.

## Install

From this repository root:

```bash
codex plugin marketplace add "$PWD"
codex plugin add worktree-guard@skills-local

claude plugin marketplace add "$PWD"
claude plugin install worktree-guard@skills-local
```

Start a new harness session after installation so it loads the hook manifest.

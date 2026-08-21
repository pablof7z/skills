# WorktreeGuard

WorktreeGuard is a lightweight accident-prevention hook for Codex, Claude
Code, and Grok Build. It has two narrow policies:

> In a Git repository's base checkout, block `git checkout`, `git clean`,
> `git rebase`, `git reset`, `git restore`, and `git switch`.
>
> Recognize ordinary native `apply_patch`, `Edit`, `Write`, `MultiEdit`,
> `NotebookEdit`, and Grok `search_replace` operations when their target is
> inside a base checkout. Shell tools include `Bash`, `Shell`, and Grok
> `run_terminal_command`.

Both are blocked in a base checkout until the agent explicitly asks for access
with `wtg request-base-access`. A write never grants itself permission; only a
request does. Once a request is granted, that harness session may both edit
files and run the six Git commands in that base checkout until the grant
expires. Every grant is bound to the current Codex, Claude Code, or Grok
session; there is no one-command scope or sessionless fallback. Everything is
always allowed in linked worktrees.

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
<plugin-root>/bin/wtg config repo <path> [full|files-only|off]
<plugin-root>/bin/wtg denials --tail 20
<plugin-root>/bin/wtg doctor
<plugin-root>/bin/wtg install-hooks
python3 <plugin-root>/scripts/probe_worktreeguard.py
python3 <plugin-root>/scripts/probe_codex_exec.py
```

`request-base-access` is the only way to obtain a grant. It is auto-granted with
a notification when `auto-grant-edits` is on, and asks through a local macOS
dialog when it is off. A request outside a detectable Codex, Claude Code, or
Grok session is refused. There is no remote approval, pairing, daemon, relay,
MCP integration, automatic branch repair, session cwd tracking, or full
allow-action audit.

`probe_codex_exec.py` is the end-to-end Codex check. It creates a disposable Git
repository, asks a real ephemeral `codex exec` session to switch branches, and
passes only when Codex reports the PreToolUse block, the branch remains `main`,
and WorktreeGuard recorded exactly one denial.

`config auto-grant-edits` prints the current preference when no value is
provided. `on` is the default.

`config repo <path> [full|files-only|off]` sets or shows a per-repo guard
mode, keyed by the repo's resolved base checkout path. `full` (the default
for any repo with no entry) blocks both the six Git commands and native file
writes in the base checkout, as described above. `files-only` disables only
the Git-command block, so the six commands run freely in the base checkout,
while native file writes there still require a grant. `off` disables the
guard entirely for that repo's base checkout; linked worktrees are already
unrestricted and are unaffected by any mode. Modes are stored in
`state.json` and, like the rest of WorktreeGuard, are a convenience
guardrail, not a security boundary — a repo set to `off` or `files-only` is
trusting the agent, not sandboxing it. Run `config repo <path>` with no mode
to print the effective mode, or `config repo --list` to list every
configured repo.

## Architecture

The shared `lib/worktreeguard/` package owns the policy and CLI. The Codex,
Claude, and Grok shims only translate their hook entrypoints into the shared
command. `hooks/hooks.json` matches shell tools (`Bash`, `Shell`,
`run_terminal_command`) and native write tools (`apply_patch`, `Edit`, `Write`,
`MultiEdit`, `NotebookEdit`, `search_replace`) for `PreToolUse` only. It
installs no other lifecycle hooks. WorktreeGuard takes no part in the harness's
own permission system; base access is requested through `wtg`, not through a
Claude, Codex, or Grok prompt.

All Git main worktrees are guarded by default. No repository registration or
protection database is required. A per-repo guard mode (see `config repo`
above) can relax that default down to `files-only` or `off` for a specific
base checkout. Local grants are stored in
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

grok plugin marketplace add "$PWD"
grok plugin install worktree-guard --trust
# Grok discovers plugin hooks but does not execute them (Grok 0.2.x).
# Register a global hook that points at the stable dispatch shim:
<path-to-plugin>/bin/wtg install-hooks
```

Start a new harness session after installation so it loads the hook manifest.
`wtg install-hooks` copies stable shims into `~/.local/bin` and writes
`~/.grok/hooks/worktree-guard.json` so Grok actually runs the guard.

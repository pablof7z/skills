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

Behavior for each repository is controlled by a local `.wtg.json` in the base
checkout root:

```json
{
  "enabled": true,
  "writes": "block",
  "allowBypass": true,
  "branchChanges": "follow"
}
```

- `enabled` (`false` = WorktreeGuard completely disabled for this repo).
- `writes`: `block` (no native edits/writes in the base), `off` (native writes
  allowed silently), or `warn` (native writes allowed but every one injects
  "You are modifying the base directory of a protected repo — are you sure
  you shouldn't be working on a git worktree?"). The six Git commands are
  always blocked while `enabled` is true, regardless of `writes`.
- `allowBypass`: `true` means `request-base-access` auto-grants (with one
  macOS notification); `false` puts a macOS approval dialog in front of you.
- `branchChanges`: controls switching the base checkout's branch
  (`git switch`, `git checkout <branch>`, `git checkout -b/-B`). `follow`
  (default) treats branch switches like the other blocked Git commands. `manual`
  means a branch switch is never auto-approved, even with `allowBypass: true` —
  it requires a human to approve a `wtg request-base-access --branch-change`
  request. `block` means branch switches are always denied and cannot be
  granted; use a linked worktree instead. Path restores (`git checkout -- file`,
  `git checkout <file>`) are not branch switches and follow the normal rules.

Missing or malformed `.wtg.json` falls back to the safe defaults per field
(`enabled: true`, `writes: "block"`, `allowBypass: true`), so a repo with no
file is guarded the same way it always was. Linked worktrees are always
unrestricted and are unaffected by any setting.

WorktreeGuard is not a security boundary. It recognizes ordinary direct Git
invocations and the target paths provided by harness-native write tools. It
does not inspect shell commands for indirect file writes or attempt to stop a
malicious or deliberately obfuscated caller.

## Commands

```bash
<plugin-root>/bin/wtg status --repo <path>
<plugin-root>/bin/wtg current --repo <path>
<plugin-root>/bin/wtg request-base-access --repo <path> --reason "<reason>"
<plugin-root>/bin/wtg request-base-access --repo <path> --branch-change --reason "<reason>"
<plugin-root>/bin/wtg config --repo <path>                     # interactive UI (or --json)
<plugin-root>/bin/wtg config --repo <path> set <key> <value>   # key: enabled|writes|allowBypass|branchChanges
<plugin-root>/bin/wtg config --repo <path> init               # write a default .wtg.json
<plugin-root>/bin/wtg denials --tail 20
<plugin-root>/bin/wtg doctor
<plugin-root>/bin/wtg install-hooks
python3 <plugin-root>/scripts/probe_worktreeguard.py
python3 <plugin-root>/scripts/probe_codex_exec.py
```

`request-base-access` is the only way to obtain a grant. When `allowBypass` is
true (the default) it is auto-granted with a notification; when false it asks
through a local macOS dialog. Pass `--branch-change` to request approval
specifically for switching the base branch — with `branchChanges: manual` it
always requires a human response (ignoring `allowBypass`), and with
`branchChanges: block` it is refused outright. A request outside a detectable
Codex, Claude Code, or Grok session is refused, and when `enabled` is false it
is a no-op (nothing is blocked, so no override is needed). There is no remote
approval, pairing, daemon, relay, MCP integration, automatic branch repair,
session cwd tracking, or full allow-action audit.

Every PreToolUse denial tells the agent what will happen if it asks for
access (auto-approved, blocked until a human responds, or automatically
denied) so it can choose a worktree instead of retrying.

`config` prints the effective configuration as JSON (merged from `.wtg.json`
with the safe defaults), or — when run in a terminal — opens an inquirer-style
UI with arrow-key navigation to edit all four settings. `config set <key> <value>`
updates one key in `.wtg.json`, creating the file if needed; `enabled` and
`allowBypass` accept true/false/on/off/yes/no/1/0, `writes` accepts
block/off/warn, and `branchChanges` accepts follow/manual/block. `config init`
writes a default `.wtg.json` and refuses to clobber an existing one. Edit the
file directly if you prefer — nothing else reads or writes it.

`probe_codex_exec.py` is the end-to-end Codex check. It creates a disposable Git
repository, asks a real ephemeral `codex exec` session to switch branches, and
passes only when Codex reports the PreToolUse block, the branch remains `main`,
and WorktreeGuard recorded exactly one denial.

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
protection database is required. A repo's `.wtg.json` (see `config` above)
relaxes or tightens that default for its own base checkout. Local grants are
stored in `~/.local/state/worktreeguard/state.json`; denials are appended to
`~/worktreeguard-denied-actions.jsonl`. Notifications are local, non-interactive,
and best-effort; notification delivery failure does not block the grant. On
macOS, WorktreeGuard prefers `terminal-notifier` when it is available so the
title, status, and message appear directly in Notification Center. It falls
back to AppleScript when no native sender is installed.

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

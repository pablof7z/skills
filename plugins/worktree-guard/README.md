# WorktreeGuard

WorktreeGuard is a lightweight accident-prevention hook for Codex, Claude
Code, and Grok Build. In a Git repository's base checkout, it governs four
independent **guard groups**:

| group | covers |
| --- | --- |
| `writes` | native `apply_patch`, `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, Grok `search_replace` |
| `branchChanges` | `git switch`, `git checkout <ref>`/`-b`/`-B` — anything that moves HEAD |
| `discard` | `git clean`, `git rebase`, `git reset`, `git restore`, and non-branch `checkout` (path restores like `git checkout -- file`) |
| `stash` | `git stash push`/`pop`/`apply`/`drop` |

`stash` is its own group, not folded into `discard`: silently displacing an
agent's own uncommitted work without it knowing is a distinct risk, not a
lesser one, even though `git stash` is technically recoverable. Shell tools
recognized for the Git commands above include `Bash`, `Shell`, and Grok
`run_terminal_command`.

Each group has two independent settings:

- **`disposition`** — what happens by default: `allow` (silent), `warn`
  (allowed, but a nudge is injected: "You are modifying/running `git X` in
  the base directory of a protected repo — are you sure you shouldn't be
  working on a git worktree?"), or `block` (refused until a grant covers it).
- **`bypass`** — only consulted when `disposition: block`: `auto` (a
  `wtg request-base-access --group <name>` request is granted automatically,
  with one local notification), `manual` (the request blocks until a human
  approves via a local dialog), or `none` (never grantable at all — a linked
  worktree is the only way out).

Every group supports every combination — there is no group that's
special-cased to a narrower set of states than another.

A grant is scoped to the group it was requested for and to the current
Codex/Claude Code/Grok session; a write or a Git command never grants itself
permission, only an explicit `wtg request-base-access` does. As a convenience
carried over from earlier versions, a grant for one `auto`-bypass group also
covers any other group that's still `auto` (a session that's been rubber-stamped
once for the lenient tier doesn't need to ask again per surface) — but a
`manual` or `none` group is never covered by a grant requested for a
different group. Everything is always allowed in linked worktrees.

Behavior for each repository is controlled by a local `.wtg.json` in the base
checkout root:

```json
{
  "enabled": true,
  "writes": { "disposition": "block", "bypass": "auto" },
  "branchChanges": { "disposition": "block", "bypass": "auto" },
  "discard": { "disposition": "block", "bypass": "auto" },
  "stash": { "disposition": "block", "bypass": "auto" }
}
```

- `enabled` — `false` disables every guard group for this repo; `wtg
  request-base-access` becomes a no-op ("no override is needed") and nothing
  is blocked or warned.
- Each of the four groups accepts `{"disposition": ..., "bypass": ...}`.
  Missing fields fall back to the safe defaults (`block`/`auto`) — so setting
  just `{"stash": {"disposition": "warn"}}` leaves `stash.bypass` at `auto`
  (unused while disposition isn't `block`) and every other group untouched.

Missing or malformed `.wtg.json`, or a field a repo's file doesn't mention,
falls back to `block`/`auto` per group (`enabled: true`), so a repo with no
file — or an old one predating a given group — is guarded, not left open.
Linked worktrees are always unrestricted and are unaffected by any setting.

**Upgrading from an older `.wtg.json`:** a pre-groups file (bare-string
`writes`/`branchChanges`, a top-level `allowBypass`) is read transparently and
upgraded on the fly — `writes: "off"` becomes `disposition: "allow"`,
`branchChanges: "follow"` defers to the legacy `allowBypass` exactly as it did
before, `"manual"`/`"block"` map to `bypass: "manual"`/`"none"`, and any group
absent from the old file (including `discard`, which previously had no
dedicated key, and `stash`, which didn't exist as a blockable command at all)
inherits `disposition: block` with `bypass` taken from the legacy
`allowBypass` if present. This means an existing repo now gets `stash`
guarded too, at the same strictness as its other blocked-by-default
surfaces — a deliberate change, not an oversight: `git stash` was simply
never blockable before this version. `write_config`/`config set`/`config`'s
interactive UI always save the new nested shape, so a repo only ever sees the
old shape once, on its first read after upgrading.

WorktreeGuard is not a security boundary. It recognizes ordinary direct Git
invocations and the target paths provided by harness-native write tools. It
does not inspect shell commands for indirect file writes (`sed -i`, `> file`,
`rm`, `mv`, a script that writes files) or attempt to stop a malicious or
deliberately obfuscated caller — that's an explicit non-goal, not a gap to
close, since reliably inspecting arbitrary shell commands for indirect file
mutation is a fundamentally different (and much larger) problem.

## Commands

```bash
<plugin-root>/bin/wtg status --repo <path>
<plugin-root>/bin/wtg current --repo <path>
<plugin-root>/bin/wtg request-base-access --repo <path> --group <name> --reason "<reason>"
<plugin-root>/bin/wtg config --repo <path>                              # interactive UI (or --json)
<plugin-root>/bin/wtg config --repo <path> set enabled <bool>
<plugin-root>/bin/wtg config --repo <path> set <group>.disposition <allow|warn|block>
<plugin-root>/bin/wtg config --repo <path> set <group>.bypass <auto|manual|none>
<plugin-root>/bin/wtg config --repo <path> init                        # write a default .wtg.json
<plugin-root>/bin/wtg denials --tail 20
<plugin-root>/bin/wtg doctor
<plugin-root>/bin/wtg install-hooks
python3 <plugin-root>/scripts/probe_worktreeguard.py
python3 <plugin-root>/scripts/probe_codex_exec.py
```

`<name>`/`<group>` is one of `writes`, `branchChanges`, `discard`, `stash`.
`request-base-access` is the only way to obtain a grant, and `--group` is
required on every call — every denial already tells the agent the exact
`--group <name>` command to run in response, so this never requires the
agent to guess a taxonomy up front. `--branch-change` still works as a
deprecated alias for `--group branchChanges`. Whether a request is
auto-granted (with a notification), blocks for a human, or is refused
outright depends entirely on that group's `bypass` setting. A request outside
a detectable Codex, Claude Code, or Grok session is refused, and when
`enabled` is false it is a no-op. There is no remote approval, pairing,
daemon, relay, MCP integration, automatic branch repair, session cwd
tracking, or full allow-action audit.

Every PreToolUse denial tells the agent what will happen if it asks for
access for that specific group (auto-approved, blocked until a human
responds, or automatically denied) so it can choose a worktree instead of
retrying.

`config` prints the effective configuration as JSON (merged from `.wtg.json`
with the safe defaults), or — when run in a terminal — opens an inquirer-style
UI with arrow-key navigation: pick a group, set its disposition, and (only if
it ends up `block`) its bypass. `config set <key> <value>` updates one leaf
in `.wtg.json`, creating the file if needed — `enabled` accepts
true/false/on/off/yes/no/1/0, `<group>.disposition` accepts
allow/warn/block, and `<group>.bypass` accepts auto/manual/none. `config
init` writes a default `.wtg.json` and refuses to clobber an existing one.
Edit the file directly if you prefer — nothing else reads or writes it.

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

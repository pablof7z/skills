# WorktreeGuard Specification

## Purpose

WorktreeGuard prevents a coding agent from accidentally changing a repository's
base checkout through its ordinary native file tools or a short list of
destructive or checkout-changing Git commands. It nudges the agent toward a
linked worktree, where those mutations are allowed.

It is a convenience guardrail, not a security control. Simplicity and a low
false-positive rate matter more than adversarial completeness.

## Product boundary

There is one product named **WorktreeGuard**. Harness-specific shims for Codex,
Claude Code, and Grok Build are adapters to the same product, not separate
variants.

WorktreeGuard evaluates shell hook events (`Bash`, `Shell`, and Grok
`run_terminal_command` / `run_terminal_cmd`) and the ordinary native mutation
tools exposed by Codex, Claude Code, and Grok: `apply_patch`, `Edit`, `Write`,
`MultiEdit`, `NotebookEdit`, and Grok `search_replace`. It does not inspect or
classify MCP calls or arbitrary tool names.

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

A shell command is denied only when all of the following are true:

1. The hook is `PreToolUse`.
2. The tool is a recognized shell tool (`Bash`, `Shell`, or Grok
   `run_terminal_command` / `run_terminal_cmd`).
3. An ordinary direct shell invocation resolves to one of the six subcommands.
4. The invocation's effective Git working directory belongs to the repository's
   main/base worktree.
5. No active local override applies.

Every other operation is allowed, including:

- the six subcommands in a linked worktree;
- all Git commands not listed above, including `add`, `commit`, `fetch`,
  `merge`, `pull`, and `worktree`;
- all non-Git shell commands;
- MCP tools and unrecognized non-shell tools;
- malformed or unrecognized input.

The parser should understand common accidental forms such as a hook-supplied
working directory, `git -C <path> ...`, `git --work-tree <path> ...`, and a
simple `cd <path> && git ...` sequence. It need not defeat aliases, nested shell
evaluation, deliberate obfuscation, or other bypass attempts.

A native mutation enters the base-edit permission policy when its ordinary
target-path field, or an `apply_patch` file header, resolves inside a
repository's main/base worktree. Targets in linked worktrees and outside the
base checkout are allowed. If a recognized native mutation supplies no target,
its hook working directory is used as the conservative fallback.

Base-checkout mutations are denied until the session holds a grant. A grant is
created only by an explicit `wtg request-base-access` call; no operation may
grant itself permission by being attempted. A grant covers both native
mutations and the six blocked Git commands in that base checkout, so an agent
that has asked once need not ask again for the other kind of operation.

The persisted `auto-grant-edits` preference controls how a request is answered,
not whether the policy applies. When it is on, the default, the request is
granted without a dialog and emits a non-interactive macOS notification stating
that the agent requested and received temporary base access. When it is off, the
request goes through the local approval dialog instead. The CLI must support
inspecting and changing it with `wtg config auto-grant-edits [on|off]`.

WorktreeGuard does not parse shell commands to discover file writes. An agent
could write through `rm`, `sed`, Python, an indirect shell, or another tool; that
is intentionally outside this accident-prevention boundary.

Repository discovery is live through Git. Main worktrees are guarded by
default; no explicit repository registration exists. A per-repo guard mode,
keyed by the repo's resolved base checkout path and stored in
`repo_modes` in state.json, may relax that default: `full` (default) blocks
both the six Git commands and native file writes; `files-only` disables only
the Git-command block while still blocking native file writes; `off`
disables both for that repo's base checkout. Linked worktrees are always
unrestricted regardless of mode. The CLI must support inspecting and
changing it with `wtg config repo <path> [full|files-only|off]`. Modes are
config, not a security boundary, exactly like the rest of this policy.

## Local override

`wtg request-base-access` obtains a short `once` or `session` override. With
`auto-grant-edits` on it is granted directly; with it off it asks the local user
through a macOS dialog. Tests may use `WTG_APPROVAL_RESPONSE`. If the dialog is
needed but unavailable or failing, the request is denied. There is no remote
fallback.

## State and diagnostics

Preferences and active local overrides are stored at
`~/.local/state/worktreeguard/state.json` unless `WTG_STATE_FILE` overrides the
path. Existing state defaults `auto-grant-edits` to on when the preference is
absent.

Denied commands are logged to `~/worktreeguard-denied-actions.jsonl` unless
`WTG_DENY_LOG_FILE` overrides the path. Allowed actions are not logged.

`wtg status` and `wtg current` report live Git context. `wtg doctor` reports
Git, state, denial-log, and stable hook-shim paths. `wtg denials` inspects the
denial log.

## Hook behavior

The shared hook manifest installs only `PreToolUse`, matching shell tools and
recognized native mutation tools including Grok's `run_terminal_command` and
`search_replace`. It installs no other lifecycle hooks. WorktreeGuard does not
participate in the harness's own permission system: it inspects what a tool is
about to do and decides, and permission for a base-checkout mutation is
requested through `wtg`, never through a harness prompt.

Grok Build 0.2.x discovers plugin-bundled hooks but does not execute them.
`wtg install-hooks` therefore installs stable shims under `~/.local/bin` and
registers `~/.grok/hooks/worktree-guard.json` so Grok runs the same policy
through its global hook path. Claude Code and Codex continue to use the plugin
manifest directly.

A denial uses only the current harness's normal hook decision JSON and exits
successfully. Claude and Codex receive
`hookSpecificOutput.permissionDecision`; Grok receives `decision`/`reason`.
These formats must never be mixed because Codex validates the entire response
and rejects Grok's `decision: deny` value as invalid. A grant-covered operation
is silent. The hook never creates a grant; it only consumes one. Hook decisions,
not process exit status, carry behavior. Failures to parse payloads or discover
repositories fail open. Session detection for grants accepts `WTG_SESSION_ID`,
`GROK_SESSION_ID`, `CLAUDE_CODE_SESSION_ID`, and `CODEX_THREAD_ID`.

## Acceptance tests

The regression probe must exercise Codex, Claude, and Grok dispatch paths and
prove:

- all six listed commands are denied in a base checkout;
- each harness denial validates as that harness's response format, without
  incompatible fields from another harness;
- all six are allowed in linked worktrees;
- representative normal Git and non-Git commands are allowed in a base;
- `git -C`, hook workdir, and simple `cd && git` resolve the correct checkout;
- all recognized native mutation tools are denied for base targets when the
  session holds no grant, with auto-grant on as well as off;
- an explicit `request-base-access` call auto-grants, notifies once, and then
  permits both native mutations and the six Git commands in that base checkout;
- a grant does not apply to a different harness session;
- native mutations remain allowed in linked worktrees and outside the base;
- MCP and unrecognized non-shell tool payloads are ignored;
- the hook manifest contains only policy events and matches the explicit shell
  and native-mutation tool names;
- a local once override allows exactly one otherwise-blocked command;
- malformed input fails open;
- only denials are logged.

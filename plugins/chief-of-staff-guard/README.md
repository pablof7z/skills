# ChiefOfStaffGuard

ChiefOfStaffGuard is an accident-prevention hook for Codex and Claude Code
that keeps the chief-of-staff agent to orchestration. It has one policy:

> When the acting harness session is a chief-of-staff session, block every
> state-mutating shell command and native file write, everywhere, except
> inside chief-of-staff's own tracking-repo home.

Everything else -- every non-chief-of-staff session, and every read-only or
coordination action a chief-of-staff session takes -- passes through
untouched.

## Why this exists

Chief-of-staff's own standing doctrine
(`agent-home/chief-of-staff/workflows/agent-coordination-standards.md`,
section 5, in `pablof7z/everything`) already says this in words:

> Chief-of-staff does not perform system-state-changing actions itself.
> Ever. This includes small doc/wording edits in project repos, git
> operations beyond read-only inspection, restarting/killing daemons, and
> publishing/writing to any live system -- even for "quick" diagnosis.

It kept getting violated anyway, three times in a single 2026-07-25 session,
each time with a plausible-sounding reason:

1. **Did git conflict resolution, merges, and pushes across several project
   repos directly**, instead of dispatching the fix to the agent already
   working that repo.
2. **Merged a project PR itself on green CI alone**, which shipped a real
   bug that an in-flight human/agent review would have caught.
3. **Personally debugged and fixed a broken TTS29 daemon** -- killing and
   restarting processes, clearing local state, publishing raw Nostr events
   to diagnose and recreate a NIP-29 group -- instead of dispatching the
   investigation from the first diagnostic step.

The doctrine's own diagnosis of *why* a written rule wasn't enough: by the
time a task turns out to be hard, the agent's context is already polluted
and it forgets to delegate. That is exactly the failure mode a technical
control fixes and a memory/prompt rule cannot -- the same reasoning behind
[WorktreeGuard](../worktree-guard/README.md), which blocks bad git
operations in a base checkout regardless of what the agent intended, rather
than trusting the agent to self-police. ChiefOfStaffGuard applies that same
philosophy to the chief-of-staff role specifically.

## How it identifies a chief-of-staff session

Mosaico's own `mosaico harness hook claude-code ...` dispatcher already
solves "which agent is this session" -- ChiefOfStaffGuard reuses that
signal rather than inventing a new one.

Mosaico's PTY supervisor sets `MOSAICO_AGENT=<slug>` on every process it
spawns for a dispatched agent (`src/pty/supervisor.rs`,
`cmd.env("MOSAICO_AGENT", &args.agent)`), and mosaico's own hook dispatcher
resolves identity from that variable first and foremost
(`src/cli.rs::agent_env_slug()`, consumed by `src/cli/hooks.rs`). This is a
real, live signal, confirmed by inspecting the running fabric and its
source during development of this plugin. `CLAUDE_CODE_AGENT` (set directly
by a `claude --agent <slug>` invocation) is used as a secondary fallback
for sessions started without going through mosaico's dispatcher at all --
mosaico's own hook code covers that same case by walking the process tree
for a live `--agent` flag; reading the env var Claude Code already
publishes is simpler and equivalent.

A session is treated as chief-of-staff when the resolved slug is exactly
`chief-of-staff`, or starts with `chief-of-staff-` (observed live in the
fabric: `chief-of-staff-codex`, the Codex-hosted instance of the identical
persona). The doctrine governs the *role*, not one harness binding, and a
false negative here (a Codex-hosted chief-of-staff session slipping through
because its slug didn't match) is worse than a false positive on some
future unrelated `chief-of-staff-*` slug -- no such unrelated agent exists
today. See `lib/chiefofstaffguard/identity.py` for the exact resolution
order and reasoning.

## The allow/block line

Directly from agent-coordination-standards.md section 5's own line between
orchestration and implementation:

**Allowed everywhere** (read-only inspection + coordination):

- `git status` / `log` / `diff` / `show` / `branch` (read-only forms; a
  branch name or a mutating flag like `-d`/`-m` is not read-only)
- `gh pr view|list|checks|diff`, `gh issue view|list`, `gh repo view`,
  `gh api` (GET-style only -- see below)
- `ls`, `cat`, `find` (no `-delete`/`-exec`), `grep`, `ps`, `lsof`, `curl`
  for plain GET/reads
- Every `mosaico` command (`dispatch`, `channel *`, `session`, `my
  session`, `doctor`, `agents list`, ...) -- this is the orchestration
  mechanism and must stay fully usable
- A small set of harmless read/text-processing utilities used to compose
  with the above: `echo`, `printf`, `pwd`, `cd`, `date`, `wc`, `head`,
  `tail`, `uniq`, `diff`, `jq`, `env`, `which`, `type`, `basename`,
  `dirname`, `file`, `stat`, `du`, `df`, `tree` (see `SAFE_BARE_COMMANDS`
  in `policy.py`)

**Allowed only inside chief-of-staff's own tracking-repo home** (the
doctrine's own explicit self-management carve-out -- editing chief-of-staff's
own workflow-memory files is "the equivalent of taking my own notes, not
fixing someone else's system"):

- `rm` / `mv` / `cp` / `tee` / output redirection (`>`, `>>`), when every
  path involved resolves inside the home
- Native file writes (`Edit`, `Write`, `MultiEdit`, `NotebookEdit`,
  `apply_patch`), when the target resolves inside the home

The home is `~/src/everything` (the `pablof7z/everything` tracking-repo
checkout) and `~/.agents/homes/chief-of-staff`, both overridable via
`COSG_TRACKING_REPO_HOME` and `COSG_AGENT_HOME` for other machines. See
`lib/chiefofstaffguard/homes.py`.

**Blocked everywhere else** (state-mutating, matching the doctrine's own
examples plus its catch-all "anything else that changes state on disk, in a
repo, or on a remote system"):

- `git commit|push|merge|rebase|reset|checkout -b|branch -d|worktree
  add|remove`, and any other git write subcommand
- `rm`/`mv`/`cp`/`tee`/redirection targeting anything outside the home
- `kill`, `pkill`, `launchctl`, `systemctl` (process/service control)
- `curl`/`wget` for anything other than a plain GET/HEAD (any `-X POST` /
  `-d` / `--data*` / `-F`/`--form` / `--upload-file`, or `gh api` with the
  same)
- `sed -i` (in-place edit), `find -delete`/`-exec`/`-execdir`/..., `sort -o`
- `gh pr merge`, `gh pr review`, `gh pr edit`, `gh pr close`, and the
  equivalent `gh issue` mutations
- Any command not on the allowlist above, including general-purpose
  interpreters (`python3`, `node`, `ruby`, ...) -- these can perform
  arbitrary I/O that no static command parse can verify, so they fail
  closed by default rather than being partially trusted

### The `gh pr create` judgment call

The task that produced this plugin explicitly flagged `gh pr create` as a
gray area and asked for a documented decision rather than a silent guess.
The line drawn here: **filing an issue or opening a PR (or commenting on
one) to hand work off to someone else is coordination -- it's the same
shape as a `mosaico dispatch`, just addressed to GitHub instead of the
fabric. Resolving one that already exists is not.** So `gh pr create`,
`gh pr comment`, `gh issue create`, and `gh issue comment` are allowed;
`gh pr merge`, `gh pr review` (approving/requesting changes undermines
exactly the review gate incident #2 shows chief-of-staff must not bypass),
`gh pr edit`, and `gh pr close` are blocked. See `GH_HANDOFF_SUBCOMMAND_PAIRS`
and `GH_READ_SUBCOMMAND_PAIRS` in `policy.py`.

## No self-serve override

Unlike WorktreeGuard's `request-base-access` (a legitimate escalation path
for a different problem -- an agent that sometimes needs to work in a base
checkout on purpose), ChiefOfStaffGuard has **no override command at all**.
If chief-of-staff genuinely needs an exception, that requires Pablo's direct
intervention (e.g. temporarily disabling the plugin) -- not an agent-driven
override. Building a self-serve escalation here would recreate exactly the
loophole the doctrine's own "ask forgiveness, not permission" framing (rule
1 of the same doctrine, which is about how chief-of-staff pushes *other*
agents, not about state mutation) could otherwise be misread to justify for
chief-of-staff's own actions.

On a block, the hook fails closed with a message that names the exact rule
violated and the concrete next step -- dispatch it:

```
ChiefOfStaffGuard blocked `gh pr merge 42 --squash`.
Reason: `gh pr merge` is not on the allowlist (view/list/checks/diff reads
and create/comment handoffs only; merge/close/edit/review are blocked)

Rule: chief-of-staff orchestrates and dispatches; it never performs
state-mutating actions itself, including small or "just diagnostic" ones
(agent-coordination-standards.md section 5, "Never do the work myself --
no exceptions for 'small' or 'diagnostic'"). This is a technical control,
not a self-discipline rule.

Dispatch the work instead, e.g.:
  mosaico dispatch <agent>@<backend> --workspace <ws> --channel <path>
  --message "<what needs doing and why>"

Self-management inside chief-of-staff's own tracking-repo checkout or
agent home is not restricted by this guard -- if that is what you meant
to do, run it from inside that checkout.

There is no agent-driven override for this guard. If this block is wrong,
stop and ask Pablo directly.
```

Every denial is appended to `~/chief-of-staff-guard-denied-actions.jsonl`
and raises a best-effort local macOS notification, so a pattern of blocks
is visible without having to go looking for it.

## Commands

```bash
<plugin-root>/bin/cosg status              # is the current session guarded, and what does it see
<plugin-root>/bin/cosg doctor              # check the local installation
<plugin-root>/bin/cosg denials --tail 20   # inspect the blocked-action log
```

## Architecture

The shared `lib/chiefofstaffguard/` package owns identity detection, policy,
and the CLI; `bin/cosg-hook-claude` and `bin/cosg-hook-codex` only translate
their hook entrypoints into the shared `cosg hook <harness> pre-tool-use`
command, mirroring WorktreeGuard's shim pattern exactly.
`hooks/hooks.json` matches `Bash|Shell|apply_patch|Edit|Write|MultiEdit|
NotebookEdit` for `PreToolUse` only -- both the shell-command policy and the
native-write-target policy apply to the same tool surface WorktreeGuard
already guards, because most real implementation work in these harnesses
happens through the `Edit`/`Write` tools, not shell heredocs.

Like WorktreeGuard, this is **not a full sandbox**. It recognizes ordinary
direct invocations of specific programs (git, gh, rm/mv/cp/tee, curl/wget,
kill/pkill, launchctl/systemctl, sed/find/sort, and plain output
redirection) and a small allowlist of read-only utilities. It does not
evaluate what a general-purpose interpreter does with its arguments, which
is exactly why interpreters are blocked by default rather than partially
trusted, and it does not attempt to stop a deliberately obfuscated caller.

The only durable state ChiefOfStaffGuard keeps is the denial log at
`~/chief-of-staff-guard-denied-actions.jsonl` (override with
`COSG_DENY_LOG_FILE`). There is no grant/session-state store, because there
is nothing to grant.

## A live example from building this plugin

While this plugin was being built, the build session itself turned out to
have inherited `MOSAICO_AGENT=chief-of-staff` and `CLAUDE_CODE_AGENT=chief-of-staff`
from process ancestry: chief-of-staff had dispatched the build task via a
backgrounded `claude -p ... --dangerously-skip-permissions` subprocess
rather than through `mosaico dispatch` to a distinct agent identity. Under
the exact policy this plugin implements, that build session's own file
writes and git operations (outside the tracking-repo home) would have been
self-blocked. That is a real instance of the pattern this doctrine exists
to prevent, just one level removed: spawning a same-identity background
subprocess is not the same as dispatching to a distinct agent, and it is
worth chief-of-staff routing task hand-offs like this one through `mosaico
dispatch` in the future so the resulting session's identity (and this
guard's policy) reflects who is actually doing the work.

## Install

From this repository root:

```bash
codex plugin marketplace add "$PWD"
codex plugin add chief-of-staff-guard@skills-local

claude plugin marketplace add "$PWD"
claude plugin install chief-of-staff-guard@skills-local
```

Start a new harness session after installation so it loads the hook
manifest.

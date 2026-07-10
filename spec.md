# Product spec: WorktreeGuard

Assumption: “Cloud Code” means **Claude Code**.

## 1. Product summary

**WorktreeGuard** is a local developer tool that prevents coding agents from modifying the protected base checkout of a Git repository. Agents can read the base checkout, but any write, branch switch, Git mutation, or ambiguous shell command must happen in a Git worktree unless the user grants a temporary base-checkout lease.

The product should not be “a Claude plugin” or “a Codex plugin.” It should be a **Rust policy engine + daemon + CLI**, with Claude Code and Codex implemented as first-party adapters. Future harnesses should only need a small adapter that translates their hook/event format into WorktreeGuard’s internal event schema.

Core behavior:

```text
Agent tries to mutate protected base checkout
  -> pre-tool hook denies, with instructions to create a worktree

Agent creates/enters worktree
  -> writes allowed

Agent truly needs base access
  -> agent runs request command with reason
  -> macOS menu bar app prompts user
  -> user grants once/session or denies
  -> hook allows only matching granted scope

Hook misses a mutation
  -> watcher detects base tree drift
  -> unauthorized mutation is rolled back
  -> event is logged and surfaced to agent/user
```

Claude Code already exposes hook events including `PreToolUse`, `WorktreeCreate`, `WorktreeRemove`, `CwdChanged`, and `FileChanged`; `PreToolUse` can block a tool call, and plugin hooks can live in a plugin’s `hooks/hooks.json`. ([Claude Platform Docs][1]) Codex exposes lifecycle hooks with common fields such as `session_id`, `cwd`, `hook_event_name`, and `permission_mode`, plus `PreToolUse` support for `Bash`, `apply_patch`, and MCP tool names. ([OpenAI Developers][2])

---

# 2. Goals

## Primary goals

1. **Protect the base checkout by default.** Agents must not modify files, Git index state, branch state, or base working-tree contents in the protected checkout.

2. **Force agent work into worktrees.** Agents should receive clear, actionable denial messages that tell them how to create or enter a worktree.

3. **Support explicit human override.** A session may receive a narrow temporary grant after the agent explains why base checkout access is required.

4. **Support Claude Code and Codex first.** These adapters should be production-grade.

5. **Stay harness-neutral.** New agent harnesses should plug in through a small adapter contract.

6. **Recover from missed hooks.** A watcher should detect and rollback unauthorized mutations in the base checkout.

7. **Be auditable.** Every denial, grant, rollback, and worktree creation should be logged.

## Non-goals

1. **Do not defend against a malicious local user with full same-user filesystem access.** This is a guardrail for agents and automation, not a hardened endpoint security product.

2. **Do not replace Git.** Use Git worktrees and Git commands as the source of truth.

3. **Do not rely only on command blacklists.** Shell is too flexible; unknown shell mutations in the base checkout should fail closed.

4. **Do not make permanent base access easy.** Grants should be narrow and expiring.

---

# 3. Product name and terminology

Working name: **WorktreeGuard**

CLI binary:

```bash
wtg
```

Daemon:

```bash
wtgd
```

Menu bar app:

```bash
WorktreeGuard.app
```

Important terms:

```text
Base checkout:
  The protected original checkout, usually on main/master.

Linked worktree:
  A Git worktree outside the base checkout where agents may work.

Protected repo:
  A Git repo registered with WorktreeGuard.

Session:
  One Claude Code, Codex, or other harness session.

Grant:
  Human-approved temporary permission for a session to mutate the base checkout.

Lease:
  Time-bound grant. Use "grant" internally and "access" in user-facing copy.

Violation:
  Unauthorized mutation attempt or detected base checkout drift.
```

Git’s own model supports one main worktree plus zero or more linked worktrees attached to the same repository, and linked worktrees have their own working directories while sharing repository metadata. ([Git][3])

---

# 4. System architecture

```text
┌─────────────────────────────┐
│ Claude Code / Codex / Agent │
└──────────────┬──────────────┘
               │ hook event
               ▼
┌─────────────────────────────┐
│ Harness adapter             │
│ wtg-hook-claude             │
│ wtg-hook-codex              │
└──────────────┬──────────────┘
               │ normalized event
               ▼
┌─────────────────────────────┐
│ wtg CLI / local IPC client  │
└──────────────┬──────────────┘
               │ Unix socket / fallback local check
               ▼
┌─────────────────────────────┐
│ wtgd daemon                 │
│ - policy engine             │
│ - grants                    │
│ - repo registry             │
│ - watcher controller        │
│ - audit log                 │
└───────┬───────────────┬─────┘
        │               │
        ▼               ▼
┌──────────────┐  ┌────────────────────┐
│ SQLite state │  │ macOS menu bar app │
└──────────────┘  └────────────────────┘
        │
        ▼
┌─────────────────────────────┐
│ File/Git watcher            │
│ rollback unauthorized drift │
└─────────────────────────────┘
```

Use four enforcement layers:

```text
Layer 1: Agent instructions
  AGENTS.md / CLAUDE.md tell agents to use worktrees.

Layer 2: Pre-tool hooks
  Block known and ambiguous mutations before execution.

Layer 3: Watcher rollback
  Detect and undo unauthorized base checkout drift.

Layer 4: Sandbox/launcher
  For harnesses that support it, start agents inside a worktree and make base read-only.
```

For Codex specifically, this layering matters because the official hook docs state that current shell interception is incomplete and that `PreToolUse` does not intercept every shell or non-shell path. ([OpenAI Developers][2]) Codex’s own sandbox model is also separate from approvals: the sandbox defines technical boundaries, while approval policy decides when an agent must ask to cross them. ([OpenAI Developers][4])

---

# 5. Core policy

## Default rule

```text
Agents may read the protected base checkout.
Agents may not mutate the protected base checkout unless a valid grant exists.
Agents should mutate linked worktrees instead.
```

## Base checkout mutations

Block these in the protected base checkout:

```text
File mutations:
  Write
  Edit
  MultiEdit
  apply_patch
  shell redirection
  tee
  cp/mv/rm/touch
  code generators
  formatters
  package-manager commands that write lockfiles/cache/state
  MCP filesystem write tools

Git state mutations:
  git checkout
  git switch
  git reset
  git restore
  git clean
  git merge
  git rebase
  git cherry-pick
  git stash pop/apply
  git pull
  git commit
  git update-index
  git update-ref
  direct edits to base checkout Git metadata

Ambiguous shell:
  any Bash/shell command in the base checkout that is not confidently read-only
```

Allow these in the protected base checkout:

```text
Read-only repo inspection:
  git status
  git diff
  git log
  git show
  git branch --show-current
  git rev-parse
  git worktree list
  rg
  grep
  find without -delete or -exec mutation
  cat
  head
  tail
  ls
  pwd

WorktreeGuard control commands:
  wtg status
  wtg create-worktree
  wtg request-base-access
  wtg current
  wtg doctor
```

Do not allow raw `git worktree add` by default. Force worktree creation through `wtg create-worktree` so path layout, branch naming, env copying, audit logging, and policy state stay consistent.

---

# 6. User-facing workflows

## 6.1 First install

```bash
brew install worktreeguard
wtg install daemon
wtg install menubar
wtg install claude
wtg install codex
```

Expected result:

```text
- wtgd registered as a launchd user service
- WorktreeGuard menu bar app installed
- Claude Code plugin installed/enabled
- Codex plugin installed/enabled or configured
- wtg available on PATH
```

## 6.2 Protect a repo

```bash
cd ~/dev/myrepo
wtg init
wtg protect
```

`wtg protect` should refuse dirty base checkouts by default:

```text
Cannot protect this repo yet.

The base checkout must be clean first:
  branch: main
  dirty files: 3

Commit, stash, discard, or run:
  wtg protect --adopt-dirty-baseline

Recommended: keep the base checkout clean and move all work to worktrees.
```

MVP should support only clean strict mode. Dirty baseline support can be later.

## 6.3 Agent tries to edit base

Agent attempts:

```bash
apply_patch ...
```

Hook returns:

```text
Denied by WorktreeGuard.

You are in the protected base checkout:
/Users/pablo/dev/myrepo

This session may read this checkout, but may not edit files, switch branches,
or mutate Git state here.

Create a worktree and continue there:

  wtg create-worktree --name <short-task-name>
  cd <printed-worktree-path>

Base access requires a human-approved reason:

  wtg request-base-access \
    --reason "<why this cannot be done in a worktree>" \
    --scope session
```

## 6.4 Agent creates worktree

```bash
wtg create-worktree --name fix-login
```

Output:

```text
/Users/pablo/dev/.worktrees/myrepo/fix-login-7f3a
```

The path should be the final stdout line to make it easy for agents to parse.

Then:

```bash
cd /Users/pablo/dev/.worktrees/myrepo/fix-login-7f3a
```

Writes are allowed there.

## 6.5 Agent requests base access

```bash
wtg request-base-access \
  --reason "Need to run the existing foreground dev server that is bound to this checkout and writes its generated client into the repo." \
  --scope session \
  --wait
```

Menu bar prompt:

```text
Claude Code wants base checkout access

Repo:      ~/dev/myrepo
Branch:    main
Session:   claude:abc123
Scope:     session, 30 minutes
Reason:    Need to run the existing foreground dev server...

Requested operation:
  Bash: npm run codegen

[Deny] [Allow once] [Allow session] [Create worktree instead]
```

If approved:

```text
Approved until 2026-07-10T08:02:00+03:00.
Retry the previous operation.
```

If denied:

```text
Denied. Create a worktree instead:
  wtg create-worktree --name <task>
```

The agent must not be able to approve its own request. Do not provide a normal `wtg approve` shell command.

---

# 7. Configuration

## 7.1 User config

Path:

```text
~/.config/worktreeguard/config.toml
```

Example:

```toml
version = 1

[defaults]
mode = "strict"
grant_ttl_seconds = 1800
worktree_root = "~/dev/.worktrees"
deny_unknown_shell_in_base = true
rollback_enabled = true
notify_on_violation = true

[ui]
menubar_enabled = true
require_user_presence_for_approval = true

[watcher]
debounce_ms = 250
rollback_tracked_files = true
remove_unauthorized_untracked = true
fail_if_base_dirty_on_start = true

[commands.read_only]
allow = [
  "git status",
  "git diff",
  "git log",
  "git show",
  "git branch --show-current",
  "git rev-parse",
  "git worktree list",
  "pwd",
  "ls",
  "cat",
  "head",
  "tail",
  "rg",
  "grep"
]

[commands.control]
allow = [
  "wtg status",
  "wtg current",
  "wtg create-worktree",
  "wtg request-base-access",
  "wtg doctor"
]
```

## 7.2 Repo config

Stored outside the repo in SQLite, with optional checked-in hints in:

```text
.wtg.toml
```

Example:

```toml
version = 1

[repo]
protected_base_refs = ["refs/heads/main", "refs/heads/master"]
worktree_name_template = "{repo}-{task}-{short_session}"
branch_name_template = "agent/{task}-{short_session}"
default_base_ref = "origin/main"

[worktree]
copy_ignored_from = ".worktreeinclude"
setup_commands = [
  "corepack install",
  "pnpm install --frozen-lockfile"
]

[ignore]
rollback_ignore = [
  ".DS_Store",
  ".idea/**",
  ".vscode/**",
  ".pytest_cache/**",
  ".mypy_cache/**",
  ".next/**",
  "node_modules/**"
]

[untracked]
allow_in_base = [
  ".env.local"
]
```

Repo config should be advisory. The authoritative policy should live in the user/daemon database so an agent cannot disable protection by editing a checked-in config file.

---

# 8. Rust workspace design

```text
worktreeguard/
  Cargo.toml

  crates/
    wtg-core/
      policy types, normalized event schema, decisions, grants

    wtg-git/
      git command wrapper, repo discovery, worktree list parsing,
      status parsing, restore/rollback operations

    wtg-policy/
      operation classifier, path resolver, grant matcher

    wtg-daemon/
      Unix socket server, state machine, request queue, event log

    wtg-cli/
      user CLI and hook entrypoint dispatcher

    wtg-watch/
      filesystem watcher, git-state poller, rollback coordinator

    wtg-adapter/
      adapter trait, shared harness utilities

    wtg-adapter-claude/
      parse Claude hook input, render Claude hook output

    wtg-adapter-codex/
      parse Codex hook input, render Codex hook output

    wtg-menubar/
      macOS tray/menu app, approval UI, notifications

    wtg-mcp/
      optional MCP server exposing safe tools:
      create_worktree, request_base_access, status

    wtg-installer/
      installs Claude/Codex plugins and launchd service

    xtask/
      packaging, test fixtures, release tasks
```

Recommended implementation choices:

```text
Async/runtime:
  tokio

CLI:
  clap

Serialization:
  serde, serde_json, toml

Storage:
  SQLite

Logging:
  tracing

Filesystem watching:
  native file watching through a Rust watcher abstraction

Git:
  call the system git binary for MVP
```

Use the system `git` binary initially. It avoids subtle mismatches around worktree metadata, sparse checkout, submodules, and future Git behavior. Wrap every Git call in one module with structured arguments, timeouts, and parsed outputs.

---

# 9. Internal event schema

All harness adapters should convert native hook input into this schema:

```json
{
  "schema_version": "wtg.hook.v1",
  "harness": {
    "name": "claude",
    "version": null
  },
  "session": {
    "id": "abc123",
    "turn_id": null,
    "tool_use_id": "toolu_123",
    "permission_mode": "default"
  },
  "event": {
    "name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {
      "command": "git checkout feature/foo"
    }
  },
  "cwd": "/Users/pablo/dev/myrepo",
  "transcript_path": "/Users/pablo/.claude/projects/.../abc123.jsonl",
  "environment": {
    "WTG_AGENT": "claude"
  }
}
```

Internal decision:

```json
{
  "decision": "deny",
  "reason": "base_checkout_mutation_requires_worktree",
  "message": "Denied by WorktreeGuard...",
  "operation_hash": "sha256:...",
  "repo_id": "sha256:...",
  "severity": "blocking",
  "suggested_commands": [
    "wtg create-worktree --name <short-task-name>",
    "wtg request-base-access --reason \"...\" --scope session"
  ]
}
```

Supported internal decisions:

```text
allow:
  Native adapter emits success/no-op.

deny:
  Native adapter emits hook-specific block shape.

context:
  Native adapter adds model-visible context where supported.

request:
  Internal state for pending human approval. Hook adapters should usually render this as deny with instructions unless the native harness supports safe defer.

rewrite:
  Reserved. Avoid in v1 except for controlled commands.
```

---

# 10. Policy decision algorithm

Pseudocode:

```rust
fn decide(event: NormalizedHookEvent) -> Decision {
    let ctx = resolve_context(event);

    if !ctx.in_git_repo {
        return Decision::allow();
    }

    let repo = match registry.lookup_by_path(ctx.cwd) {
        Some(repo) => repo,
        None => return Decision::allow(),
    };

    let op = classify_operation(&event, &ctx);

    if op.is_wtg_control_command() {
        return Decision::allow();
    }

    if op.is_worktree_creation_request() {
        return Decision::allow();
    }

    if !op.can_mutate() && op.is_confidently_read_only() {
        return Decision::allow();
    }

    let touches_base = path_policy::touches_protected_base(&repo, &op, &ctx);

    if !touches_base {
        return Decision::allow();
    }

    if grant_store.has_valid_grant(&repo, &ctx.session, &op) {
        return Decision::allow();
    }

    if op.is_unknown_shell() && ctx.cwd_is_base_checkout {
        return Decision::deny_worktree_required(repo, op);
    }

    if op.can_mutate() {
        return Decision::deny_worktree_required(repo, op);
    }

    Decision::allow()
}
```

Path resolution requirements:

```text
- Always canonicalize paths.
- Resolve symlinks.
- Compare real paths or inode-equivalent identities.
- Treat paths under base checkout as protected.
- Treat symlinks from worktree into base as protected base access.
- Never trust string prefix checks without canonicalization.
```

Repo identity:

```text
repo_id = sha256(realpath(git_common_dir) + "\0" + realpath(base_path))
```

Use Git for repo discovery:

```bash
git rev-parse --show-toplevel
git rev-parse --git-dir
git rev-parse --git-common-dir
git worktree list --porcelain -z
```

---

# 11. Operation classifier

## 11.1 Tool classification

```text
Read tools:
  Read, Glob, Grep, LS, git status, git diff, git log

File write tools:
  Claude: Write, Edit, MultiEdit, NotebookEdit
  Codex: apply_patch
  MCP: mcp__filesystem__write_file, mcp__filesystem__edit_file, unknown MCP tools with write/destructive annotations

Shell:
  Bash, Shell, terminal commands

Worktree control:
  wtg create-worktree
  wtg request-base-access
  wtg status
```

## 11.2 Shell command policy

Shell is the hard part. Default:

```text
If cwd is protected base checkout:
  known read-only command -> allow
  WorktreeGuard control command -> allow
  anything else -> deny unless grant exists
```

This means tests and package managers should run in worktrees. That is intentional.

Examples:

```text
Allowed in base:
  git status
  git diff -- src/foo.ts
  rg "login" src
  cat package.json
  wtg create-worktree --name login-fix

Denied in base:
  npm test
  pnpm install
  cargo fmt
  git switch feature/foo
  git checkout -b fix/foo
  python -c 'open("x","w").write("y")'
  echo hi > file.txt
```

For worktrees:

```text
Allow normal mutating commands unless they target the protected base path.
Use sandbox/watcher to catch shell attempts that write from worktree into base.
```

## 11.3 Git command classification

Read-only Git commands:

```text
git status
git diff
git log
git show
git branch --show-current
git rev-parse
git worktree list
git remote -v
git ls-files
```

Mutating Git commands:

```text
git add
git checkout
git switch
git reset
git restore
git clean
git merge
git rebase
git cherry-pick
git revert
git stash push/pop/apply
git pull
git commit
git tag
git update-index
git update-ref
git worktree add/remove/move/repair/prune
```

In v1, only allow `git worktree list` directly. Route create/remove through `wtg`.

---

# 12. Grants and approval model

## Grant scopes

```text
operation:
  Allows one matching operation hash.

session:
  Allows base mutation for this repo + harness session until expiry.

handoff:
  User-initiated lease for moving worktree changes into base checkout.

admin:
  Future. Explicitly configured trusted automation.
```

Default:

```text
scope = operation
ttl = 30 minutes maximum
```

Session grants should be available but visually more serious in the UI.

## Grant matching

A grant should match:

```text
repo_id
base_path
harness name
session_id
scope
operation_hash, if operation-scoped
expiry
current base HEAD, unless grant says allow_head_drift
```

Operation hash should include:

```text
repo_id
harness
session_id
cwd
tool_name
normalized tool input
target paths
current base branch
current base HEAD
```

Including `HEAD` prevents old approvals from silently applying after the base checkout moves.

## No self-approval

The CLI should support:

```bash
wtg request-base-access
```

The CLI should not support:

```bash
wtg approve
```

Approval must come from the menu bar app or another trusted human UI channel.

---

# 13. macOS menu bar app

## Responsibilities

```text
- Show protected repo status.
- Show pending access requests.
- Allow/deny grants.
- Show rollback notifications.
- Revoke active grants.
- Open worktree directory.
- Open audit log.
```

## Pending request UI

Fields:

```text
Harness:
  Claude Code / Codex / other

Repo:
  ~/dev/myrepo

Current base branch:
  main

Current base HEAD:
  abc1234

Session:
  claude:abc123

Requested scope:
  once / session

Reason:
  Agent-supplied reason

Attempted operation:
  tool name + normalized preview

Risk:
  base checkout mutation
```

Buttons:

```text
Deny
Allow once
Allow session
Create worktree instead
Revoke all for session
```

“Create worktree instead” should create a worktree and cause future hook denials for that session to mention the specific path.

## Approval security

The daemon should accept approval commands only from the menu bar app over a privileged local channel. At minimum:

```text
- no public approve CLI
- socket lives under user-owned 0700 runtime dir
- approval endpoint requires an in-memory UI capability token
- token is not placed in environment variables
- grants are written by daemon, not by hook scripts
- optional macOS user presence check before session grants
```

---

# 14. Daemon and IPC

## Runtime files

```text
~/.local/state/worktreeguard/wtg.sqlite
~/.local/state/worktreeguard/wtgd.log
~/.local/state/worktreeguard/run/wtgd.sock
~/.local/state/worktreeguard/locks/<repo-id>.lock
```

## IPC

Use a local Unix socket with JSON request/response.

Endpoints:

```text
POST /v1/check
POST /v1/repos/init
POST /v1/repos/protect
POST /v1/worktrees/create
POST /v1/access/request
POST /v1/access/approve
POST /v1/access/deny
POST /v1/grants/revoke
GET  /v1/status
GET  /v1/events
```

Hook calls must be fast. Target:

```text
p50 check: < 20 ms
p95 check: < 100 ms
hard timeout: 1 second
```

Fallback behavior if daemon is unavailable:

```text
Outside protected repo:
  allow

Read-only operation in protected repo:
  allow

Mutating or unknown operation in protected base checkout:
  deny fail-closed with daemon-start instructions
```

---

# 15. SQLite schema

```sql
CREATE TABLE repos (
  id TEXT PRIMARY KEY,
  base_path TEXT NOT NULL,
  common_git_dir TEXT NOT NULL,
  protected_refs_json TEXT NOT NULL,
  expected_branch TEXT NOT NULL,
  expected_head TEXT NOT NULL,
  worktree_root TEXT NOT NULL,
  mode TEXT NOT NULL,
  rollback_enabled INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  harness TEXT NOT NULL,
  harness_session_id TEXT NOT NULL,
  repo_id TEXT,
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  metadata_json TEXT NOT NULL
);

CREATE TABLE worktrees (
  id TEXT PRIMARY KEY,
  repo_id TEXT NOT NULL,
  path TEXT NOT NULL,
  branch TEXT,
  base_ref TEXT NOT NULL,
  base_head TEXT NOT NULL,
  session_id TEXT,
  state TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  removed_at INTEGER
);

CREATE TABLE access_requests (
  id TEXT PRIMARY KEY,
  repo_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  harness TEXT NOT NULL,
  reason TEXT NOT NULL,
  requested_scope TEXT NOT NULL,
  operation_hash TEXT,
  operation_json TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  resolved_at INTEGER
);

CREATE TABLE grants (
  id TEXT PRIMARY KEY,
  repo_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  harness TEXT NOT NULL,
  scope TEXT NOT NULL,
  operation_hash TEXT,
  reason TEXT NOT NULL,
  approved_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE TABLE events (
  id TEXT PRIMARY KEY,
  repo_id TEXT,
  session_id TEXT,
  type TEXT NOT NULL,
  severity TEXT NOT NULL,
  message TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
```

---

# 16. Watcher and rollback spec

The watcher is a backstop, not the main policy mechanism.

## Watch targets

For every protected repo:

```text
- base checkout directory
- base checkout Git state, checked via Git polling
- selected config files:
  .wtg.toml
  AGENTS.md
  CLAUDE.md
  .claude/**
  .codex/**
```

Do not blindly rollback the entire shared `.git` common directory. Linked worktrees legitimately mutate shared Git metadata. Instead, periodically verify the base checkout’s observable Git state:

```bash
git symbolic-ref --short HEAD
git rev-parse HEAD
git status --porcelain=v1 -z
```

## Rollback flow

```text
1. Watcher receives file events.
2. Debounce.
3. Acquire repo lock.
4. Check for valid grant.
5. If grant exists, record audit event and do not rollback.
6. If no grant, compute status delta.
7. Restore tracked modified/deleted files.
8. Remove unauthorized untracked files.
9. Restore base branch/HEAD if changed.
10. Emit audit event and menu notification.
11. Store last violation for agent feedback.
```

Tracked rollback:

```bash
git restore --source "$EXPECTED_HEAD" --staged --worktree -- <paths>
```

Unauthorized untracked rollback:

```bash
rm -rf -- <path>
```

Branch drift rollback:

```bash
git switch "$EXPECTED_BRANCH"
git reset --hard "$EXPECTED_HEAD"
```

Never run a broad `git clean -fdx` without a policy. It can delete ignored secrets, local config, and caches.

## Watcher modes

```text
strict:
  rollback unauthorized changes

audit:
  log only

off:
  disabled

lease:
  active human grant; audit but do not rollback
```

Default:

```text
strict
```

## Dirty base handling

MVP:

```text
Base checkout must be clean before protection starts.
```

Future:

```text
Allow adopted dirty baseline by storing hashes and restoring to that baseline.
```

---

# 17. Worktree creation spec

Command:

```bash
wtg create-worktree --name fix-login
```

Defaults:

```text
Root:
  ~/dev/.worktrees/<repo-name>/

Path:
  ~/dev/.worktrees/<repo-name>/<task>-<short-session>

Branch:
  agent/<task>-<short-session>

Base ref:
  origin/main if available, otherwise current protected HEAD
```

Implementation:

```bash
git fetch --quiet --prune origin    # optional, configurable
git worktree add -b "$BRANCH" "$PATH" "$BASE_REF"
```

Requirements:

```text
- Worktree path must not be inside the protected base checkout.
- Branch name must be unique.
- Path must be unique.
- Record worktree in SQLite.
- Copy ignored files only from approved include list.
- Run setup commands only if configured.
- Print final worktree path as final stdout line.
```

Support `.worktreeinclude` semantics:

```text
.env
.env.local
config/secrets.json
```

Claude Code and Codex both have worktree concepts, but their behavior differs. Claude Code has configurable worktree settings including base ref behavior, symlinked directories, sparse paths, and background isolation; Codex worktrees are documented for Codex in the ChatGPT desktop app and use Git worktrees under the hood. ([Claude Platform Docs][5]) WorktreeGuard should therefore provide its own cross-harness worktree creation command instead of depending on one harness’s implementation.

---

# 18. Claude Code adapter

## Packaging

```text
worktreeguard-claude/
  .claude-plugin/plugin.json
  hooks/hooks.json
  bin/wtg-hook-claude
```

Claude Code supports plugin hooks in `hooks/hooks.json`, and hook scripts can reference `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PROJECT_DIR}`, and `${CLAUDE_PLUGIN_DATA}`. ([Claude Platform Docs][1])

## Hook config

```json
{
  "description": "Require agent writes to happen in WorktreeGuard-managed Git worktrees",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/bin/wtg-hook-claude",
            "args": ["session-start"],
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/bin/wtg-hook-claude",
            "args": ["pre-tool-use"],
            "timeout": 5
          }
        ]
      }
    ],
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/bin/wtg-hook-claude",
            "args": ["worktree-create"],
            "timeout": 60
          }
        ]
      }
    ],
    "WorktreeRemove": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/bin/wtg-hook-claude",
            "args": ["worktree-remove"],
            "timeout": 30
          }
        ]
      }
    ],
    "CwdChanged": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/bin/wtg-hook-claude",
            "args": ["cwd-changed"],
            "timeout": 5
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/bin/wtg-hook-claude",
            "args": ["session-end"],
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

## Claude deny output

Claude `PreToolUse` can return `hookSpecificOutput.permissionDecision = "deny"` with a reason; `deny` prevents the tool call and the reason is shown to Claude. ([Claude Platform Docs][1])

Adapter output:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Denied by WorktreeGuard.\n\nYou are in the protected base checkout..."
  }
}
```

## Claude WorktreeCreate handling

Claude’s `WorktreeCreate` hook replaces Claude Code’s default Git worktree behavior and must return the absolute path to the created worktree. The docs also note that when this hook replaces default behavior, `.worktreeinclude` is not processed by Claude, so WorktreeGuard must do any local file copying itself. ([Claude Platform Docs][1])

For `WorktreeCreate`, `wtg-hook-claude worktree-create` should:

```text
1. Read hook input.
2. Extract session_id, cwd, name.
3. Call wtgd /v1/worktrees/create.
4. Print only the absolute worktree path to stdout.
5. Send logs to stderr.
```

Output:

```text
/Users/pablo/dev/.worktrees/myrepo/feature-auth-a1b2
```

## Claude-specific advantage

Claude Code already has `worktree.bgIsolation`; its settings documentation says the default `"worktree"` mode blocks background `Edit`/`Write` in the main checkout until `EnterWorktree` is called. ([Claude Platform Docs][5]) WorktreeGuard should still enforce foreground and shell/MCP paths because the product policy is broader than Claude’s built-in background isolation.

---

# 19. Codex adapter

## Packaging

```text
worktreeguard-codex/
  .codex-plugin/plugin.json
  hooks/hooks.json
  bin/wtg-hook-codex
```

Codex plugins can bundle lifecycle hooks; plugin hook commands receive `PLUGIN_ROOT` and `PLUGIN_DATA`, and Codex also sets Claude-compatible plugin env vars. Plugin hooks use the same event schema as regular Codex hooks and require review/trust before running unless managed policy is used. ([OpenAI Developers][2])

## Hook config

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$PLUGIN_ROOT/bin/wtg-hook-codex session-start",
            "timeout": 5,
            "statusMessage": "Registering WorktreeGuard session"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash|apply_patch|Edit|Write|mcp__.*",
        "hooks": [
          {
            "type": "command",
            "command": "$PLUGIN_ROOT/bin/wtg-hook-codex pre-tool-use",
            "timeout": 5,
            "statusMessage": "Checking WorktreeGuard policy"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "Bash|apply_patch|Edit|Write|mcp__.*",
        "hooks": [
          {
            "type": "command",
            "command": "$PLUGIN_ROOT/bin/wtg-hook-codex permission-request",
            "timeout": 10,
            "statusMessage": "Checking WorktreeGuard approval"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash|apply_patch|Edit|Write|mcp__.*",
        "hooks": [
          {
            "type": "command",
            "command": "$PLUGIN_ROOT/bin/wtg-hook-codex post-tool-use",
            "timeout": 5,
            "statusMessage": "Recording WorktreeGuard tool result"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$PLUGIN_ROOT/bin/wtg-hook-codex stop",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Codex currently documents command hooks as the runnable handler type, with `prompt` and `agent` handler types parsed but skipped; commands run with the session `cwd`. ([OpenAI Developers][2])

## Codex deny output

Codex `PreToolUse` supports this block shape:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Denied by WorktreeGuard..."
  }
}
```

Codex also documents a `PermissionRequest` shape where a hook can return a deny decision with a message. ([OpenAI Developers][2])

PermissionRequest deny:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Denied by WorktreeGuard. Create a worktree instead."
    }
  }
}
```

## Codex worktree handling

Codex worktrees are documented for Codex in the ChatGPT desktop app, and the docs say worktrees are available only in Codex in the ChatGPT desktop app. ([OpenAI Developers][6]) Therefore the Codex adapter should not assume every Codex surface can create/enter a native Codex worktree. It should guide the agent to:

```bash
wtg create-worktree --name <task>
cd <printed-path>
```

For Codex Desktop users who use native Handoff into Local, WorktreeGuard should require a temporary handoff lease. Otherwise the watcher may interpret the Local mutation as unauthorized base drift.

---

# 20. Generic harness adapter protocol

Every future harness gets two small pieces:

```text
1. parser:
   native hook JSON -> NormalizedHookEvent

2. renderer:
   Decision -> native hook output
```

Rust trait:

```rust
pub trait HarnessAdapter {
    fn harness_name(&self) -> &'static str;

    fn parse_event(
        &self,
        stdin: &[u8],
        env: &std::collections::HashMap<String, String>,
    ) -> anyhow::Result<NormalizedHookEvent>;

    fn render_decision(
        &self,
        decision: PolicyDecision,
        native_event_name: &str,
    ) -> anyhow::Result<AdapterOutput>;
}
```

Adapter output:

```rust
pub struct AdapterOutput {
    pub stdout_json: Option<serde_json::Value>,
    pub stderr: Option<String>,
    pub exit_code: i32,
}
```

Generic installation pattern:

```bash
wtg install harness --name hermes \
  --pre-tool-command "wtg hook generic --harness hermes"
```

For harnesses without hooks:

```bash
wtg run --agent some-agent --repo ~/dev/myrepo -- some-agent-cli
```

`wtg run` should:

```text
1. Resolve protected repo.
2. Create or select a worktree.
3. cd into worktree.
4. Export WTG_SESSION_ID, WTG_HARNESS, WTG_BASE_PATH, WTG_WORKTREE_PATH.
5. Optionally sandbox base checkout as read-only.
6. Exec the agent process.
```

---

# 21. CLI spec

```bash
wtg init [--repo PATH]
wtg protect [--repo PATH]
wtg unprotect [--repo PATH]
wtg status [--repo PATH]
wtg current

wtg create-worktree \
  [--repo PATH] \
  --name NAME \
  [--base-ref REF] \
  [--branch BRANCH] \
  [--print-env]

wtg list-worktrees [--repo PATH]
wtg remove-worktree PATH [--force]

wtg request-base-access \
  [--repo PATH] \
  --reason TEXT \
  [--scope operation|session] \
  [--wait] \
  [--timeout SECONDS]

wtg grants list
wtg grants revoke GRANT_ID
wtg events tail [--repo PATH]

wtg daemon
wtg doctor
wtg install daemon
wtg install menubar
wtg install claude
wtg install codex
wtg uninstall claude
wtg uninstall codex

wtg hook claude
wtg hook codex
wtg hook generic --harness NAME
```

`wtg doctor` should check:

```text
- git available
- daemon running
- menu bar app running
- Claude plugin installed
- Codex plugin installed/trusted where detectable
- protected repos are clean
- watcher active
- hooks executable
- socket permissions
```

---

# 22. Audit events

Event examples:

```json
{
  "type": "tool_denied",
  "severity": "info",
  "repo": "/Users/pablo/dev/myrepo",
  "harness": "codex",
  "session_id": "s_123",
  "tool_name": "Bash",
  "reason": "base_checkout_mutation_requires_worktree",
  "command": "git checkout feature/foo"
}
```

```json
{
  "type": "base_mutation_reverted",
  "severity": "warning",
  "repo": "/Users/pablo/dev/myrepo",
  "expected_branch": "main",
  "expected_head": "abc123",
  "paths": [
    {
      "path": "src/auth.ts",
      "kind": "tracked_modified",
      "action": "git_restore"
    },
    {
      "path": "tmp.txt",
      "kind": "untracked_created",
      "action": "removed"
    }
  ]
}
```

```json
{
  "type": "grant_created",
  "severity": "notice",
  "repo": "/Users/pablo/dev/myrepo",
  "harness": "claude",
  "session_id": "abc123",
  "scope": "session",
  "expires_at": 1783670520,
  "reason": "Need base checkout for foreground dev server"
}
```

---

# 23. Agent-facing messages

## Base mutation denial

```text
Denied by WorktreeGuard.

You are in the protected base checkout:
{base_path}

This session may read this checkout, but may not edit files, switch branches,
or mutate Git state here.

Create a worktree and continue there:

  wtg create-worktree --name <short-task-name>
  cd <printed-worktree-path>

If base access is truly required, request a human grant with a specific reason:

  wtg request-base-access \
    --reason "<why this cannot be done in a worktree>" \
    --scope session
```

## Branch switch denial

```text
Denied by WorktreeGuard.

Do not switch branches in the protected base checkout:
{base_path}

Use a worktree for branch-specific work:

  wtg create-worktree --name <branch-or-task-name> --base-ref {current_ref}
  cd <printed-worktree-path>
```

## Watcher rollback notice

```text
WorktreeGuard reverted your previous base-checkout mutation.

Reverted paths:
  - src/auth.ts
  - tmp-output.txt

Continue in a worktree instead:

  wtg create-worktree --name <short-task-name>
```

---

# 24. Security and threat model

## Protected against

```text
- Agent accidentally editing base checkout.
- Agent switching base checkout away from main/master.
- Agent running ambiguous shell in base checkout.
- Agent using apply_patch/Edit/Write in base checkout.
- Agent using common filesystem MCP write tools.
- Hook misses followed by observable file drift.
```

## Not fully protected against

```text
- Malicious same-user process killing daemon or editing files while watcher is stopped.
- Kernel/root compromise.
- Side effects outside the repo, such as databases, cloud resources, package caches.
- Very short-lived mutations consumed by another process before rollback.
- Harnesses with no hook support unless launched through wtg run or sandboxed.
```

## Hardening recommendations

```text
- Run agents through wtg run when possible.
- Keep base checkout read-only in sandbox when harness supports writable-root policy.
- Keep protected base clean.
- Keep worktree root outside base checkout.
- Make config/state files user-owned 0600/0700.
- Use launchd KeepAlive for wtgd.
- Fail closed for unknown shell in base.
- Never expose approval through normal shell.
```

Codex’s local security model explicitly separates sandbox boundaries from approval behavior, and the docs recommend keeping the project boundary as default and using separate projects or worktrees rather than broadly expanding access. ([OpenAI Developers][4])

---

# 25. Implementation milestones

## Milestone 1: Core CLI and policy engine

Deliver:

```text
- Rust workspace skeleton
- repo discovery
- repo registry
- strict clean-base protection
- normalized event schema
- command classifier
- path resolver
- SQLite state
- wtg status
- wtg init
- wtg protect
- wtg create-worktree
- wtg hook generic with JSON input/output
```

Acceptance:

```text
- protected clean repo registered
- worktree created outside base
- writes in worktree allowed
- base mutating operation denied by generic check
```

## Milestone 2: Claude Code adapter

Deliver:

```text
- Claude plugin package
- PreToolUse denial
- SessionStart registration
- CwdChanged tracking
- WorktreeCreate integration
- WorktreeRemove audit
```

Acceptance:

```text
- Claude Write/Edit/Bash in base denied
- Claude WorktreeCreate returns WorktreeGuard path
- Claude worktree writes allowed
- denial message is model-actionable
```

## Milestone 3: Codex adapter

Deliver:

```text
- Codex plugin package
- PreToolUse denial for Bash/apply_patch/MCP
- PermissionRequest deny/allow from grants
- PostToolUse event logging
- installer guidance for plugin trust
```

Acceptance:

```text
- Codex apply_patch in base denied
- Codex Bash git switch in base denied
- Codex can run wtg create-worktree
- worktree writes allowed
```

## Milestone 4: Daemon and grants

Deliver:

```text
- wtgd Unix socket
- access request queue
- grants table
- request-base-access CLI
- grant matching
- revocation
- event log
```

Acceptance:

```text
- agent can request access with reason
- no shell approval path exists
- manually inserted/test UI grant allows matching operation
- expired grant denies again
```

## Milestone 5: macOS menu bar

Deliver:

```text
- pending request popover
- notifications
- allow once/session
- deny
- revoke
- create worktree instead
```

Acceptance:

```text
- request triggers user-visible prompt
- approval creates grant
- denial leaves operation blocked
- grant expiry visible
```

## Milestone 6: Watcher rollback

Deliver:

```text
- base checkout watcher
- Git state poller
- tracked restore
- unauthorized untracked removal
- branch drift repair
- audit events
- violation feedback surfaced to future hooks
```

Acceptance:

```text
- unauthorized file edit in base is reverted
- unauthorized new file in base is removed
- unauthorized git switch is restored to expected branch/head
- grant suppresses rollback during lease
```

## Milestone 7: Generic launcher and sandbox support

Deliver:

```text
- wtg run --agent
- automatic worktree startup
- env injection
- optional read-only base mount/sandbox integrations
```

Acceptance:

```text
- arbitrary agent launched in worktree
- base path communicated as read-only context
- watcher still protects base
```

---

# 26. Test plan

## Unit tests

```text
Path resolver:
  - symlink from worktree into base is treated as base access
  - relative paths resolve against cwd
  - paths with .. cannot escape classification

Command classifier:
  - git status allowed
  - git switch denied
  - echo > file denied in base
  - python -c unknown denied in base
  - wtg create-worktree allowed

Grant matcher:
  - operation grant matches same operation
  - operation grant fails on different HEAD
  - session grant expires
  - revoked grant fails

Patch parser:
  - apply_patch target paths extracted
  - absolute paths rejected/normalized
```

## Integration tests

Use temporary Git repos.

```text
- protect clean main repo
- deny base file write
- deny base branch switch
- allow read-only git commands
- create worktree
- allow worktree file write
- deny worktree write through symlink into base
- watcher restores tracked edit
- watcher removes unauthorized untracked file
- watcher restores branch drift
```

## Adapter golden tests

Fixtures:

```text
fixtures/claude/pre_tool_use_bash_git_switch.json
fixtures/claude/pre_tool_use_write.json
fixtures/claude/worktree_create.json

fixtures/codex/pre_tool_use_apply_patch.json
fixtures/codex/pre_tool_use_bash.json
fixtures/codex/permission_request.json
```

Assert native output exactly matches expected hook JSON.

## End-to-end tests

```text
- simulated Claude hook invocation
- simulated Codex hook invocation
- daemon unavailable fail-closed behavior
- request approval through test UI client
- concurrent hook calls with repo lock
```

---

# 27. Recommended defaults

Use these defaults for v1:

```text
mode:
  strict

base checkout:
  must be clean

unknown shell in base:
  deny

raw git worktree add:
  deny; tell agent to use wtg create-worktree

grant TTL:
  30 minutes

grant default scope:
  operation

session grant:
  allowed, but user must explicitly choose it

watcher:
  enabled

rollback:
  tracked restore enabled
  untracked removal enabled except allowlist
  ignored paths not removed by default

worktree root:
  sibling directory outside base checkout

approval:
  menu bar only
  no approve CLI
```

---

# 28. Key product decisions

## Decision 1: Make worktree creation your own primitive

Even though Claude Code and Codex have worktree features, WorktreeGuard should own `wtg create-worktree`. This keeps behavior consistent across harnesses, and it lets you standardize setup, ignored-file copying, branch names, cleanup, and audit logs.

## Decision 2: Fail closed for unknown shell in base

This will block some legitimate commands in the base checkout. That is acceptable because the product’s point is to stop agents from doing work there.

## Decision 3: Use watcher rollback as backstop only

The watcher makes the product robust, but it is after-the-fact. Hooks and sandboxing should prevent mutations before they happen; the watcher repairs missed paths.

## Decision 4: Keep adapters thin

The Claude and Codex adapters should contain almost no policy. They should only translate:

```text
native hook input -> normalized event
policy decision -> native hook output
```

## Decision 5: No self-approval path

Agents can request access. Humans approve access. Keep that boundary strict.

[1]: https://docs.anthropic.com/en/docs/claude-code/hooks "Hooks reference - Claude Code Docs"
[2]: https://developers.openai.com/codex/hooks "
  Hooks | ChatGPT Learn
"
[3]: https://git-scm.com/docs/git-worktree?utm_source=chatgpt.com "Git - git-worktree Documentation"
[4]: https://developers.openai.com/codex/concepts/sandboxing "
  Sandbox | ChatGPT Learn
"
[5]: https://docs.anthropic.com/en/docs/claude-code/settings "Claude Code settings - Claude Code Docs"
[6]: https://developers.openai.com/codex/app/worktrees "
  Worktrees | ChatGPT Learn
"

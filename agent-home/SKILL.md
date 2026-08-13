---
name: agent-home
description: Resolve and use a durable private home directory at ~/.agents/home/{identifier} for agent-only notes, scripts, caches, drafts, and other state that must persist across sessions.
---

# Agent Home

Use one durable directory for private state that belongs to this agent across
sessions. Do not use it for project-shared files, team-owned state, or
recreatable build output.

## Core rule

Store agent-only persistent state under:

`~/.agents/home/{identifier}/`

Resolve `{identifier}` at agent scope:

1. Prefer the stable agent identity. When context distinguishes `Agent`,
   `Session`, and `Backend`, use `Agent`.
2. Do not use a session handle, codename, thread ID, or backend-qualified
   session reference when an agent identity is available.
3. Otherwise use a stable local agent name such as `codex`, `claude`, or
   `harry`.
4. Preserve an explicitly supplied opaque identity. Normalize a name by
   lower-casing it, replacing characters outside `[a-z0-9._-]` with `-`,
   collapsing repeated `-`, and trimming leading or trailing `-`.
5. Use `agent` if normalization is empty.

Create the directory before using it and write private persistent files only
inside it.

## Resolver

Pass the resolved agent identity explicitly when it is known:

```bash
~/.agents/skills/agent-home/scripts/resolve-agent-home.sh codex
```

With no argument, the helper checks common runtime-provided agent identity and
name values, then falls back to `agent`.

Suitable contents include private notes, helper scripts, lightweight caches,
drafts, logs, and artifacts needed by later sessions of the same agent.

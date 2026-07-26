"""Detect whether the acting harness session is a chief-of-staff session.

Mosaico's own `mosaico harness hook claude-code ...` dispatcher resolves
"which agent is this session" primarily from the `MOSAICO_AGENT` environment
variable. It is set by the PTY supervisor on every process it spawns for a
dispatched agent (mosaico `src/pty/supervisor.rs`:
`cmd.env("MOSAICO_AGENT", &args.agent)`), and read back via `agent_env_slug()`
in mosaico `src/cli.rs`, which mosaico's own hook dispatcher
(`src/cli/hooks.rs`) treats as authoritative whenever present. That is the
existing, harness-agnostic identity signal reused here rather than inventing
a new one.

`CLAUDE_CODE_AGENT` is a secondary, Claude-Code-native fallback: it is set
directly by a `claude --agent <slug>` invocation itself, so it still
identifies a chief-of-staff session that was started without going through
mosaico's dispatcher. Mosaico's own hook code handles that same case by
walking the process tree for a live `--agent` flag; reading the env var
Claude Code already publishes is simpler and equivalent for this purpose, and
only takes over when `MOSAICO_AGENT` is not set at all.

The fabric also runs harness-variant slugs for the same role (observed live:
`chief-of-staff-codex`, the Codex-hosted instance of the identical
chief-of-staff persona, alongside the Claude-hosted `chief-of-staff`). The
doctrine in agent-coordination-standards.md governs the *role*, not one
specific harness binding, so a slug of `chief-of-staff` or anything prefixed
`chief-of-staff-` is treated as chief-of-staff here. This is a deliberate
judgment call: the risk of a false negative (a Codex-hosted chief-of-staff
session implementing directly because its slug did not match) is worse than
the risk of a false positive on some future, unrelated `chief-of-staff-*`
slug, and no such unrelated agent exists today.
"""

from __future__ import annotations

from typing import Mapping

from .core import CHIEF_OF_STAFF_SLUG

MOSAICO_AGENT_ENV = "MOSAICO_AGENT"
CLAUDE_CODE_AGENT_ENV = "CLAUDE_CODE_AGENT"
CHIEF_OF_STAFF_SLUG_PREFIX = f"{CHIEF_OF_STAFF_SLUG}-"


def is_chief_of_staff_slug(slug: str) -> bool:
    return slug == CHIEF_OF_STAFF_SLUG or slug.startswith(CHIEF_OF_STAFF_SLUG_PREFIX)


def is_chief_of_staff_session(env: Mapping[str, str]) -> bool:
    """Return whether `env` belongs to a chief-of-staff harness session.

    `MOSAICO_AGENT` wins whenever it is set, matching mosaico's own
    resolution order: if it names a *different* agent, this is not a
    chief-of-staff session even if a stale `CLAUDE_CODE_AGENT` says
    otherwise (e.g. inherited by a plain subprocess spawned from a
    chief-of-staff shell). Only fall back to `CLAUDE_CODE_AGENT` when
    Mosaico did not set an agent at all.
    """
    mosaico_agent = (env.get(MOSAICO_AGENT_ENV) or "").strip()
    if mosaico_agent:
        return is_chief_of_staff_slug(mosaico_agent)
    claude_agent = (env.get(CLAUDE_CODE_AGENT_ENV) or "").strip()
    return is_chief_of_staff_slug(claude_agent)

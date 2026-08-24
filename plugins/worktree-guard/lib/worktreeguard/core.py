"""Small shared types and helpers for WorktreeGuard."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


BLOCKED_GIT_COMMANDS = frozenset(
    {"checkout", "clean", "rebase", "reset", "restore", "stash", "switch"}
)

# Every blocked Git subcommand routes to exactly one guard group, each independently
# configurable (see storage.RepoConfig / storage.GroupPolicy). "checkout" is
# ambiguous on its own: a path restore (`git checkout -- file`) is a "discard", but
# `git checkout <ref>` or `-b`/`-B` is a "branchChanges" — policy.git_command_group()
# resolves it using the same branch-change detection as before. Every other blocked
# subcommand maps statically:
GIT_COMMAND_GROUPS = {
    "switch": "branchChanges",
    "clean": "discard",
    "rebase": "discard",
    "reset": "discard",
    "restore": "discard",
    "stash": "stash",
}

# The four independently configurable guard groups: "writes" covers native-tool file
# writes; the rest cover the Git subcommands above (via GIT_COMMAND_GROUPS and
# checkout's branch-change detection).
GUARD_GROUPS = ("writes", "branchChanges", "discard", "stash")

DEFAULT_GRANT_TTL_SECONDS = 30 * 60
DEFAULT_DENY_LOG_FILE = "worktreeguard-denied-actions.jsonl"
DEFAULT_REQUEST_LOG_FILE = "worktreeguard-base-access-requests.jsonl"


@dataclass(frozen=True)
class Repo:
    base_path: Path
    worktree_path: Path
    branch: str
    head: str


class WorktreeGuardError(RuntimeError):
    pass


def resolve_path(raw_path: str | Path) -> Path:
    return Path(raw_path).expanduser().resolve(strict=False)


def emit(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")

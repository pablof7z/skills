"""Small shared types and helpers for WorktreeGuard."""

from __future__ import annotations

import json
import os
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


BLOCKED_GIT_COMMANDS = frozenset(
    {"checkout", "clean", "rebase", "reset", "restore", "switch"}
)
DEFAULT_GRANT_TTL_SECONDS = 30 * 60
DEFAULT_DENY_LOG_FILE = "worktreeguard-denied-actions.jsonl"


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


def command_name() -> str:
    raw = os.environ.get("WTG_COMMAND") or sys.argv[0] or "wtg"
    return "wtg" if raw == "wtg" else shlex.quote(str(resolve_path(raw)))


def emit(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")

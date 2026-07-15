"""Shared types, constants, and small utilities for WorktreeGuard-lite."""

from __future__ import annotations

import json
import os
import shlex
import sys
from pathlib import Path
from typing import Any

READ_ONLY_TOOLS = {"Read", "Glob", "Grep", "LS"}
WRITE_TOOLS = {"apply_patch", "Edit", "Write", "MultiEdit", "NotebookEdit"}
DANGEROUS_GIT_COMMANDS = {
    "checkout",
    "clean",
    "rebase",
    "reset",
    "restore",
    "switch",
}
DEFAULT_GRANT_TTL_SECONDS = 30 * 60
DEFAULT_ACTION_LOG_FILE = "worktreeguard-actions.jsonl"
DEFAULT_DENY_LOG_FILE = "worktreeguard-denied-actions.jsonl"
SHELL_CONTROL_TOKENS = {"&&", "||", ";", "|"}
ANSI_RESET = "\033[0m"
ANSI_BOLD = "\033[1m"
ANSI_DIM = "\033[2m"
ANSI_RED = "\033[31m"
ANSI_GREEN = "\033[32m"
ANSI_YELLOW = "\033[33m"
ANSI_BLUE = "\033[34m"
ANSI_MAGENTA = "\033[35m"
ANSI_CYAN = "\033[36m"


def resolve_path(raw_path: str | Path) -> Path:
    return Path(raw_path).expanduser().resolve(strict=False)


def path_contains(parent: Path, child: Path) -> bool:
    try:
        child.relative_to(parent)
    except ValueError:
        return False
    return True


def command_name() -> str:
    raw = os.environ.get("WTG_COMMAND") or sys.argv[0] or "wtg"
    if raw == "wtg":
        return "wtg"
    return shlex.quote(str(resolve_path(raw)))


def emit(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


class WorktreeGuardError(RuntimeError):
    pass


class Repo:
    def __init__(
        self,
        *,
        base_path: Path,
        worktree_path: Path,
        common_git_dir: Path,
        branch: str,
        head: str,
    ) -> None:
        self.base_path = base_path
        self.worktree_path = worktree_path
        self.common_git_dir = common_git_dir
        self.branch = branch
        self.head = head

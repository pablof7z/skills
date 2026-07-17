"""Messages and records for the only event WorktreeGuard logs: a denial."""

from __future__ import annotations

import shlex
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .core import command_name
from .operations import payload_string
from .policy import BlockedGitOperation


def denial_message(operation: BlockedGitOperation) -> str:
    return (
        f"WorktreeGuard blocked `git {operation.subcommand}` in the base checkout:\n"
        f"{operation.base_path}\n\n"
        "Run it from a linked worktree instead. WorktreeGuard does not restrict "
        "other Git commands, non-Git shell commands, file edits, patches, or MCP tools.\n\n"
        "If this base-checkout command is intentional, request a short local override:\n"
        f"  {command_name()} request-base-access --repo "
        f"{shlex.quote(str(operation.base_path))} --reason \"<why>\""
    )


def denial_record(
    *, event: str, payload: dict[str, Any], operation: BlockedGitOperation
) -> dict[str, Any]:
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "session_id": payload_string(
            payload, "session_id", "sessionId", "conversation_id", "conversationId",
            "thread_id", "threadId",
        ),
        "turn_id": payload_string(payload, "turn_id", "turnId"),
        "base_path": str(operation.base_path),
        "effective_cwd": str(operation.cwd),
        "subcommand": operation.subcommand,
        "command": operation.command,
    }

"""Messages and records for the only event WorktreeGuard logs: a denial."""

from __future__ import annotations

import shlex
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .operations import payload_string
from .policy import BlockedFileOperation, BlockedGitOperation, BlockedOperation


def denial_message(operation: BlockedOperation) -> str:
    if isinstance(operation, BlockedGitOperation):
        summary = f"`git {operation.subcommand}` in the base checkout"
        detail = f"\nRejected command:\n{operation.command}"
    else:
        summary = f"the native `{operation.tool_name}` tool in the base checkout"
        detail = f"\nTarget: {operation.target}" if operation.target is not None else ""
    return (
        f"WorktreeGuard blocked {summary}:\n{operation.base_path}{detail}\n\n"
        "Shouldn't you be working on a Git worktree?\n\n"
        "If you really meant to work in the base checkout, use "
        f"`wtg request-base-access --repo {shlex.quote(str(operation.base_path))} "
        "--reason \"<why>\"` to request permission."
    )


def denial_record(
    *, event: str, payload: dict[str, Any], operation: BlockedOperation
) -> dict[str, Any]:
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "session_id": payload_string(
            payload, "session_id", "sessionId", "conversation_id", "conversationId",
            "thread_id", "threadId",
        ),
        "turn_id": payload_string(payload, "turn_id", "turnId"),
        "base_path": str(operation.base_path),
        "effective_cwd": str(operation.cwd),
    }
    if isinstance(operation, BlockedGitOperation):
        record.update(subcommand=operation.subcommand, command=operation.command)
    elif isinstance(operation, BlockedFileOperation):
        record.update(
            tool_name=operation.tool_name,
            target=str(operation.target) if operation.target is not None else None,
        )
    return record

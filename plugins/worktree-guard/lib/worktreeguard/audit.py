"""Messages and records for the two events WorktreeGuard logs: a denial or a base-access request."""

from __future__ import annotations

import shlex
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .operations import payload_string
from .policy import BlockedFileOperation, BlockedGitOperation, BlockedOperation
from .storage import RepoConfig


def denial_message(operation: BlockedOperation, config: RepoConfig) -> str:
    if isinstance(operation, BlockedGitOperation):
        summary = f"`git {operation.subcommand}` in the base checkout"
        detail = f"\nRejected command:\n{operation.command}"
    else:
        summary = f"the native `{operation.tool_name}` tool in the base checkout"
        detail = f"\nTarget: {operation.target}" if operation.target is not None else ""
    hint = approval_hint(config, operation.base_path, getattr(operation, "branch_change", False))
    return (
        f"WorktreeGuard blocked {summary}:\n{operation.base_path}{detail}\n\n"
        f"Shouldn't you be working on a Git worktree?\n\n{hint}"
    )


def approval_hint(config: RepoConfig, base_path: Path, is_branch_change: bool) -> str:
    """Tell the agent what happens if it requests access for this operation."""
    base = shlex.quote(str(base_path))
    if is_branch_change and config.branch_changes == "block":
        return (
            "Changing the base branch is automatically denied for this repo — a request "
            "won't help. Use a linked worktree instead."
        )
    if is_branch_change and config.branch_changes == "manual":
        cmd = f"wtg request-base-access --branch-change --repo {base} --reason \"<why>\""
        return (
            "A request to change the branch will block until the user manually responds "
            f"(auto-approval is disabled for branch changes). If you really meant to, use `{cmd}`."
        )
    cmd = f"wtg request-base-access --repo {base} --reason \"<why>\""
    if config.allow_bypass:
        return f"A request will be automatically approved. If you really meant to, use `{cmd}`."
    return f"A request will block until the user manually responds. If you really meant to, use `{cmd}`."


def warn_message(operation: BlockedFileOperation) -> str:
    detail = f"\nTarget: {operation.target}" if operation.target is not None else ""
    return (
        "You are modifying the base directory of a protected repo — are you sure "
        "you shouldn't be working on a git worktree?"
        f"\n{operation.base_path}{detail}"
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
        record.update(
            subcommand=operation.subcommand,
            command=operation.command,
            branch_change=operation.branch_change,
        )
    elif isinstance(operation, BlockedFileOperation):
        record.update(
            tool_name=operation.tool_name,
            target=str(operation.target) if operation.target is not None else None,
        )
    return record


def request_record(
    *, base_path: Path, reason: str, session_id: str, approved: bool, method: str,
) -> dict[str, Any]:
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event": "request-base-access",
        "base_path": str(base_path),
        "reason": reason,
        "session_id": session_id,
        "approved": approved,
        "method": method,
    }
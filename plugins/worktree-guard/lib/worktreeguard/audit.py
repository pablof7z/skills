"""Messages and records for the two events WorktreeGuard logs: a denial or a base-access request."""

from __future__ import annotations

import shlex
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .operations import payload_string
from .policy import BlockedFileOperation, BlockedGitOperation, BlockedOperation
from .storage import RepoConfig


# Human-readable label for each guard group, used in hint/warning prose.
GROUP_LABELS = {
    "writes": "native file writes",
    "branchChanges": "branch changes",
    "discard": "history/working-tree discards (clean/reset/restore/rebase)",
    "stash": "git stash",
}


def denial_message(operation: BlockedOperation, config: RepoConfig) -> str:
    if isinstance(operation, BlockedGitOperation):
        summary = f"`git {operation.subcommand}` in the base checkout"
        detail = f"\nRejected command:\n{operation.command}"
    else:
        summary = f"the native `{operation.tool_name}` tool in the base checkout"
        detail = f"\nTarget: {operation.target}" if operation.target is not None else ""
    hint = approval_hint(config, operation.base_path, operation.group)
    return (
        f"WorktreeGuard blocked {summary}:\n{operation.base_path}{detail}\n\n"
        f"Shouldn't you be working on a Git worktree?\n\n{hint}"
    )


def approval_hint(config: RepoConfig, base_path: Path, group: str) -> str:
    """Tell the agent what happens if it requests access for this group."""
    label = GROUP_LABELS.get(group, group)
    bypass = config.policy(group).bypass
    if bypass == "none":
        return (
            f"{label.capitalize()} are automatically denied for this repo — a request "
            "won't help. Use a linked worktree instead."
        )
    cmd = f'wtg request-base-access --group {group} --repo {shlex.quote(str(base_path))} --reason "<why>"'
    if bypass == "manual":
        return (
            f"A request for {label} will block until the user manually responds "
            f"(auto-approval is disabled for this group). If you really meant to, use `{cmd}`."
        )
    return f"A request will be automatically approved. If you really meant to, use `{cmd}`."


def warn_message(operation: BlockedOperation) -> str:
    if isinstance(operation, BlockedGitOperation):
        lead = f"You are running `git {operation.subcommand}` in the base directory of a protected repo"
        detail = f"\nCommand: {operation.command}"
    else:
        lead = "You are modifying the base directory of a protected repo"
        detail = f"\nTarget: {operation.target}" if operation.target is not None else ""
    return (
        f"{lead} — are you sure you shouldn't be working on a git worktree?"
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
        "group": operation.group,
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
    *, base_path: Path, reason: str, session_id: str, approved: bool, method: str, group: str | None,
) -> dict[str, Any]:
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event": "request-base-access",
        "base_path": str(base_path),
        "reason": reason,
        "session_id": session_id,
        "approved": approved,
        "method": method,
        "group": group,
    }

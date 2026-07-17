"""Hook decisions and audit-record persistence."""

from __future__ import annotations

import shlex
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .core import command_name, resolve_path
from .operations import operation_workdir, payload_string
from .storage import (
    action_log_path,
    deny_log_path,
    read_jsonl_records,
    write_jsonl_record,
)


def denial_message(base_path: Path) -> str:
    command = command_name()
    return (
        "Denied by WorktreeGuard.\n\n"
        "You are in the protected base checkout:\n"
        f"{base_path}\n\n"
        "This session may read and build from this checkout, but may not change "
        "tracked or unignored repository files, switch branches, or mutate the "
        "protected checkout state here. Git-ignored build and generated artifacts "
        "are allowed.\n\n"
        "Continue from a Git worktree instead. Use the repository's normal "
        "worktree workflow; WorktreeGuard will allow mutations outside this "
        "protected base checkout.\n\n"
        "If base access is truly required, ask for a human approval:\n\n"
        f"  {command} request-base-access --repo {shlex.quote(str(base_path))} \\\n"
        "    --reason \"<why this cannot be done in a worktree>\" \\\n"
        "    --scope session\n\n"
        "If this denial appears to be a WorktreeGuard bug because the operation "
        "should have been allowed, and tenex-edge fabric is available, join "
        "`skills.worktree-guard` and leave a bug note there without tagging any agent."
    )


def log_action(
    *,
    event: str,
    payload: dict[str, Any],
    base_path: Path | None,
    cwd: Path,
    operation: dict[str, Any],
    decision: str,
    reason: str,
    protected: dict[str, Any] | None = None,
) -> None:
    write_action_log(
        action_record(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            decision=decision,
            reason=reason,
            protected=protected,
        )
    )


def action_record(
    *,
    event: str,
    payload: dict[str, Any],
    base_path: Path | None,
    cwd: Path,
    operation: dict[str, Any],
    decision: str,
    reason: str,
    protected: dict[str, Any] | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    tool_input = operation.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    record: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "session_id": payload_string(
            payload,
            "session_id",
            "sessionId",
            "conversation_id",
            "conversationId",
            "thread_id",
            "threadId",
        ),
        "turn_id": payload_string(payload, "turn_id", "turnId"),
        "transcript_path": payload_string(payload, "transcript_path", "transcriptPath"),
        "base_path": str(base_path or ""),
        "payload_cwd": str(resolve_path(str(payload.get("cwd") or ""))) if payload.get("cwd") else "",
        "effective_cwd": str(cwd),
        "operation_workdir": operation_workdir(tool_input),
        "tool_input_keys": sorted(str(key) for key in tool_input.keys()),
        "tool_name": str(operation.get("tool_name") or ""),
        "command": str(operation.get("command") or ""),
        "decision": decision,
        "reason": reason,
    }
    if protected:
        record["protected"] = True
        record["default_protected"] = bool(protected.get("default_protected"))
        record["protected_branch"] = str(protected.get("branch") or "")
    else:
        record["protected"] = False
        record["default_protected"] = False
        record["protected_branch"] = ""
    if extra:
        record.update(extra)
    return record


def write_action_log(record: dict[str, Any]) -> None:
    write_jsonl_record(action_log_path(), record)


def write_denial_log(record: dict[str, Any]) -> None:
    write_jsonl_record(deny_log_path(), record)


def read_action_records() -> list[dict[str, Any]]:
    return read_jsonl_records(action_log_path())


def read_denial_records() -> list[dict[str, Any]]:
    return read_jsonl_records(deny_log_path())

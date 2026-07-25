"""Messages and records for the only event ChiefOfStaffGuard logs: a denial."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from .operations import payload_string
from .policy import BlockedFileOperation, BlockedOperation, BlockedShellOperation


def denial_message(operation: BlockedOperation) -> str:
    if isinstance(operation, BlockedShellOperation):
        subject = f"`{operation.command}`" if operation.command else "this command"
    else:
        target = f" (target: {operation.target})" if operation.target is not None else ""
        subject = f"the native `{operation.tool_name}` tool{target}"
    return (
        f"ChiefOfStaffGuard blocked {subject}.\n"
        f"Reason: {operation.reason}\n\n"
        "Rule: chief-of-staff orchestrates and dispatches; it never performs "
        "state-mutating actions itself, including small or \"just diagnostic\" ones "
        "(agent-coordination-standards.md section 5, \"Never do the work myself -- "
        "no exceptions for 'small' or 'diagnostic'\"). This is a technical control, "
        "not a self-discipline rule.\n\n"
        "Dispatch the work instead, e.g.:\n"
        '  mosaico dispatch <agent>@<backend> --workspace <ws> --channel <path> '
        '--message "<what needs doing and why>"\n\n'
        "Self-management inside chief-of-staff's own tracking-repo checkout or "
        "agent home is not restricted by this guard -- if that is what you meant "
        "to do, run it from inside that checkout.\n\n"
        "There is no agent-driven override for this guard. If this block is "
        "wrong, stop and ask Pablo directly."
    )


def denial_record(*, event: str, payload: dict[str, Any], operation: BlockedOperation) -> dict[str, Any]:
    record: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "session_id": payload_string(
            payload, "session_id", "sessionId", "conversation_id", "conversationId",
            "thread_id", "threadId",
        ),
        "turn_id": payload_string(payload, "turn_id", "turnId"),
        "cwd": str(operation.cwd),
        "reason": operation.reason,
    }
    if isinstance(operation, BlockedShellOperation):
        record.update(program=operation.program, command=operation.command)
    elif isinstance(operation, BlockedFileOperation):
        record.update(
            tool_name=operation.tool_name,
            target=str(operation.target) if operation.target is not None else None,
        )
    return record

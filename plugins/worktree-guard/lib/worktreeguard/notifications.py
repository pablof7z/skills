"""Non-blocking user awareness for native base-edit auto grants."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from .policy import BlockedFileOperation


def notify_auto_grant(operation: BlockedFileOperation, *, session_id: str) -> None:
    target = f" Target: {operation.target}." if operation.target is not None else ""
    message = (
        "An agent granted itself temporary permission to edit the base checkout "
        f"{operation.base_path}.{target} Disable with: wtg config auto-grant-edits off."
    )
    test_log = os.environ.get("WTG_NOTIFICATION_LOG_FILE")
    if test_log:
        write_test_notification(Path(test_log), operation, session_id, message)
        return
    if sys.platform != "darwin":
        return
    script = (
        f'display notification "{apple_script_string(message)}" '
        'with title "WorktreeGuard" subtitle "Base edit auto-granted"'
    )
    try:
        subprocess.run(
            ["osascript", "-e", script], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=2, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass


def apple_script_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def write_test_notification(
    path: Path, operation: BlockedFileOperation, session_id: str, message: str
) -> None:
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "title": "WorktreeGuard",
        "subtitle": "Base edit auto-granted",
        "message": message,
        "base_path": str(operation.base_path),
        "target": str(operation.target) if operation.target is not None else None,
        "tool_name": operation.tool_name,
        "session_id": session_id,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        pass

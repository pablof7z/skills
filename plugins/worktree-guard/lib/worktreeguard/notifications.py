"""Non-blocking user awareness for auto-granted base-access requests."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def notify_auto_grant(base_path: Path, *, reason: str, session_id: str) -> None:
    message = (
        "An agent requested and was auto-granted temporary permission to mutate the "
        f"base checkout {base_path}. Reason: {reason}. "
        "Require approval with: wtg config auto-grant-edits off."
    )
    test_log = os.environ.get("WTG_NOTIFICATION_LOG_FILE")
    if test_log:
        write_test_notification(Path(test_log), base_path, reason, session_id, message)
        return
    if sys.platform != "darwin":
        return
    script = (
        f'display notification "{apple_script_string(message)}" '
        'with title "WorktreeGuard" subtitle "Base access auto-granted"'
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
    path: Path, base_path: Path, reason: str, session_id: str, message: str
) -> None:
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "title": "WorktreeGuard",
        "subtitle": "Base access auto-granted",
        "message": message,
        "base_path": str(base_path),
        "reason": reason,
        "session_id": session_id,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        pass

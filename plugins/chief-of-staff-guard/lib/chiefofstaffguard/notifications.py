"""Non-blocking local awareness when ChiefOfStaffGuard blocks an action."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def notify_denial(*, reason: str, session_id: str) -> None:
    message = f"ChiefOfStaffGuard blocked a chief-of-staff action: {reason}"
    test_log = os.environ.get("COSG_NOTIFICATION_LOG_FILE")
    if test_log:
        write_test_notification(Path(test_log), reason, session_id, message)
        return
    if sys.platform != "darwin":
        return
    terminal_notifier = shutil.which("terminal-notifier")
    if terminal_notifier and deliver([
        terminal_notifier,
        "-title", "ChiefOfStaffGuard",
        "-subtitle", "Blocked a self-implementation action",
        "-message", message,
    ]):
        return
    script = (
        f'display notification "{apple_script_string(message)}" '
        'with title "ChiefOfStaffGuard" subtitle "Blocked a self-implementation action"'
    )
    deliver(["osascript", "-e", script])


def deliver(command: list[str]) -> bool:
    try:
        result = subprocess.run(
            command, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=2, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def apple_script_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def write_test_notification(path: Path, reason: str, session_id: str, message: str) -> None:
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "title": "ChiefOfStaffGuard",
        "subtitle": "Blocked a self-implementation action",
        "message": message,
        "reason": reason,
        "session_id": session_id,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        pass

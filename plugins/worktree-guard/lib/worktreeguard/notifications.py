"""Non-blocking user awareness for auto-granted base-access requests."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def notify_auto_grant(base_path: Path, *, reason: str, session_id: str, group: str) -> None:
    message = (
        "An agent requested and was auto-granted temporary permission to mutate the "
        f"base checkout {base_path} (group: {group}). Reason: {reason}. "
        "Require manual approval for this group with: wtg config --repo "
        f"{base_path} set {group}.bypass manual."
    )
    test_log = os.environ.get("WTG_NOTIFICATION_LOG_FILE")
    if test_log:
        write_test_notification(Path(test_log), base_path, reason, session_id, message)
        return
    if sys.platform != "darwin":
        return
    terminal_notifier = shutil.which("terminal-notifier")
    if terminal_notifier and deliver([
        terminal_notifier,
        "-title", "WorktreeGuard",
        "-subtitle", "Base access auto-granted",
        "-message", message,
    ]):
        return
    script = (
        f'display notification "{apple_script_string(message)}" '
        'with title "WorktreeGuard" subtitle "Base access auto-granted"'
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

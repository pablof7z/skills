"""Non-blocking user awareness for auto-granted base-access requests."""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from .core import group_for_access_scope
from .install import toast_binary_path

AUTO_GRANT_TOAST_SECONDS = 8


def iterm_focus_command() -> str:
    """A shell command that jumps back to the iTerm2 tab running this process.

    Empty when not running inside iTerm2, or when the bundled AppleScript
    wasn't installed (``install-hooks`` copies it next to ``wtg-toast``).
    """
    session_id = os.environ.get("ITERM_SESSION_ID", "").strip()
    if not session_id or sys.platform != "darwin":
        return ""
    uuid = session_id.rsplit(":", 1)[-1]
    script = toast_binary_path().parent / "wtg-focus-iterm.applescript"
    if not script.is_file():
        return ""
    return f"osascript {shlex.quote(str(script))} {shlex.quote(uuid)}"


def notify_auto_grant(
    base_path: Path, *, reason: str, session_id: str, scope: str, grant_id: str,
) -> None:
    policy_key = group_for_access_scope(scope)
    message = (
        "An agent requested and was auto-granted session access to mutate the "
        f"base checkout {base_path} (scope: {scope}). Reason: {reason}. "
        "Require manual approval for this scope with: wtg config --repo "
        f"{base_path} set {policy_key}.bypass manual."
    )
    test_log = os.environ.get("WTG_NOTIFICATION_LOG_FILE")
    if test_log:
        write_test_notification(Path(test_log), base_path, reason, session_id, message)
        return
    if sys.platform != "darwin":
        return

    toast = toast_binary_path()
    if toast.is_file():
        revoke_command = f"wtg revoke --repo {shlex.quote(str(base_path))} --grant-id {shlex.quote(grant_id)}"
        launch_detached([
            str(toast), base_path.name, scope, "0", reason,
            str(AUTO_GRANT_TOAST_SECONDS), iterm_focus_command(), revoke_command,
        ])
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


def launch_detached(command: list[str]) -> None:
    try:
        subprocess.Popen(
            command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError:
        pass


def deliver(command: list[str]) -> bool:
    try:
        result = subprocess.run(
            command, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=15, check=False,
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

"""Focused tests for native macOS notification delivery."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.notifications import notify_auto_grant  # noqa: E402


MISSING_TOAST = Path("/nonexistent/wtg-toast")


class NotificationTests(unittest.TestCase):
    """These exercise the legacy terminal-notifier/osascript fallback, used only
    when the native toast binary (built by ``install-hooks``) isn't present —
    see ``test_toast.py`` for the primary, toast-first delivery path."""

    @patch("worktreeguard.notifications.toast_binary_path", return_value=MISSING_TOAST)
    @patch("worktreeguard.notifications.sys.platform", "darwin")
    @patch("worktreeguard.notifications.subprocess.run")
    @patch("worktreeguard.notifications.shutil.which")
    def test_prefers_native_notification_sender(self, which, run, _toast) -> None:
        which.return_value = "/opt/homebrew/bin/terminal-notifier"
        run.return_value = subprocess.CompletedProcess([], 0)

        notify_auto_grant(
            Path("/repo"), reason="requested edit", session_id="session",
            scope="writes", grant_id="grant-1",
        )

        run.assert_called_once()
        command = run.call_args.args[0]
        self.assertEqual(command[0], "/opt/homebrew/bin/terminal-notifier")
        self.assertIn("WorktreeGuard", command)
        self.assertIn("Base access auto-granted", command)
        message = command[command.index("-message") + 1]
        self.assertIn("requested edit", message)

    @patch("worktreeguard.notifications.toast_binary_path", return_value=MISSING_TOAST)
    @patch("worktreeguard.notifications.sys.platform", "darwin")
    @patch("worktreeguard.notifications.subprocess.run")
    @patch("worktreeguard.notifications.shutil.which")
    def test_falls_back_when_native_sender_fails(self, which, run, _toast) -> None:
        which.return_value = "/usr/local/bin/terminal-notifier"
        run.side_effect = [
            subprocess.CompletedProcess([], 1),
            subprocess.CompletedProcess([], 0),
        ]

        notify_auto_grant(
            Path("/repo"), reason="requested edit", session_id="session",
            scope="writes", grant_id="grant-1",
        )

        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0][0], which.return_value)
        self.assertEqual(run.call_args_list[1].args[0][:2], ["osascript", "-e"])

    @patch("worktreeguard.notifications.toast_binary_path", return_value=MISSING_TOAST)
    @patch("worktreeguard.notifications.sys.platform", "darwin")
    @patch("worktreeguard.notifications.subprocess.run")
    @patch("worktreeguard.notifications.shutil.which", return_value=None)
    def test_uses_apple_script_without_native_sender(self, _which, run, _toast) -> None:
        run.return_value = subprocess.CompletedProcess([], 0)

        notify_auto_grant(
            Path("/repo"), reason="requested edit", session_id="session",
            scope="writes", grant_id="grant-1",
        )

        run.assert_called_once()
        self.assertEqual(run.call_args.args[0][:2], ["osascript", "-e"])


if __name__ == "__main__":
    unittest.main()

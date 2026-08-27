"""The native toast: revoke precision, iTerm focus command, and the
toast-first delivery/approval paths in notifications.py and storage.py."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.core import Repo  # noqa: E402
from worktreeguard.notifications import iterm_focus_command, notify_auto_grant  # noqa: E402
from worktreeguard.storage import (  # noqa: E402
    ApprovalOutcome, create_grant, load_state, request_human_approval, revoke_grants, save_state,
)

FAKE_TOAST = Path("/fake/wtg-toast")


class RevokeGrantIdTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-revoke-")
        self.state = Path(self.temporary.name) / "state.json"
        self.environment = patch.dict("os.environ", {"WTG_STATE_FILE": str(self.state)})
        self.environment.start()

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def test_grant_id_only_revokes_the_matching_grant(self) -> None:
        save_state({"version": 9, "grants": [
            {"id": "grant-a", "base_path": "/repo", "scope": "writes", "session_id": "s1"},
            {"id": "grant-b", "base_path": "/repo", "scope": "discard", "session_id": "s1"},
        ]})

        removed = revoke_grants(Path("/repo"), grant_id="grant-a")

        self.assertEqual(removed, 1)
        remaining_ids = {g["id"] for g in load_state()["grants"]}
        self.assertEqual(remaining_ids, {"grant-b"})

    def test_missing_grant_id_removes_nothing(self) -> None:
        save_state({"version": 9, "grants": [
            {"id": "grant-a", "base_path": "/repo", "scope": "writes", "session_id": "s1"},
        ]})

        removed = revoke_grants(Path("/repo"), grant_id="does-not-exist")

        self.assertEqual(removed, 0)
        self.assertEqual(len(load_state()["grants"]), 1)


class ItermFocusCommandTests(unittest.TestCase):
    @patch("worktreeguard.notifications.sys.platform", "darwin")
    @patch("worktreeguard.notifications.toast_binary_path")
    def test_builds_osascript_command_from_session_id(self, toast_path) -> None:
        toast_path.return_value = FAKE_TOAST
        script = FAKE_TOAST.parent / "wtg-focus-iterm.applescript"
        with patch("worktreeguard.notifications.Path.is_file", return_value=True):
            with patch.dict("os.environ", {"ITERM_SESSION_ID": "w0t2p0:ABCD-1234"}):
                command = iterm_focus_command()
        self.assertIn(str(script), command)
        self.assertIn("ABCD-1234", command)
        self.assertNotIn("w0t2p0", command)  # only the UUID half is passed through

    @patch.dict("os.environ", {}, clear=True)
    def test_empty_without_iterm_session_id(self) -> None:
        self.assertEqual(iterm_focus_command(), "")


class NotifyAutoGrantToastTests(unittest.TestCase):
    @patch("worktreeguard.notifications.sys.platform", "darwin")
    @patch("worktreeguard.notifications.launch_detached")
    @patch("worktreeguard.notifications.iterm_focus_command", return_value="")
    @patch("worktreeguard.notifications.toast_binary_path")
    def test_launches_toast_detached_with_grant_scoped_revoke(
        self, toast_path, _focus, launch_detached,
    ) -> None:
        toast_path.return_value = FAKE_TOAST
        with patch.object(Path, "is_file", return_value=True):
            notify_auto_grant(
                Path("/repo"), reason="editing config", session_id="session",
                scope="writes", grant_id="grant-xyz",
            )

        launch_detached.assert_called_once()
        command = launch_detached.call_args.args[0]
        self.assertEqual(command[0], str(FAKE_TOAST))
        self.assertIn("writes", command)
        self.assertIn("0", command)  # mode: auto-approved, not pending
        self.assertIn("editing config", command)
        revoke_command = command[-1]
        self.assertIn("wtg revoke", revoke_command)
        self.assertIn("--grant-id grant-xyz", revoke_command)


class RequestHumanApprovalToastTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Repo(base_path=Path("/repo"), worktree_path=Path("/repo"), branch="main", head="abc")

    @patch("worktreeguard.storage.sys.platform", "darwin")
    @patch("worktreeguard.storage.subprocess.run")
    @patch("worktreeguard.install.toast_binary_path")
    def test_approve_outcome_grants_access(self, toast_path, run) -> None:
        toast_path.return_value = FAKE_TOAST
        run.return_value = subprocess.CompletedProcess([], 0, stdout="approve\n")
        with patch.object(Path, "is_file", return_value=True):
            outcome = request_human_approval(repo=self.repo, reason="need it", scope="writes", timeout=5)
        self.assertEqual(outcome, ApprovalOutcome.APPROVED)
        self.assertEqual(run.call_args.args[0][0], str(FAKE_TOAST))

    @patch("worktreeguard.storage.sys.platform", "darwin")
    @patch("worktreeguard.storage.subprocess.run")
    @patch("worktreeguard.install.toast_binary_path")
    def test_reject_and_timeout_outcomes_deny_access(self, toast_path, run) -> None:
        toast_path.return_value = FAKE_TOAST
        with patch.object(Path, "is_file", return_value=True):
            for outcome, expected in (
                ("reject", ApprovalOutcome.REJECTED),
                ("timeout", ApprovalOutcome.TIMED_OUT),
            ):
                run.return_value = subprocess.CompletedProcess([], 0, stdout=f"{outcome}\n")
                result = request_human_approval(repo=self.repo, reason="need it", scope="writes", timeout=5)
                self.assertEqual(result, expected)

    def test_env_override_short_circuits_before_touching_toast(self) -> None:
        with patch.dict("os.environ", {"WTG_APPROVAL_RESPONSE": "allow"}):
            outcome = request_human_approval(repo=self.repo, reason="need it", scope="writes", timeout=5)
        self.assertEqual(outcome, ApprovalOutcome.APPROVED)


if __name__ == "__main__":
    unittest.main()

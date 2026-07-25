"""End-to-end tests for the PreToolUse hook: identity gate + deny decision."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from chiefofstaffguard.hooks import run_harness_hook  # noqa: E402


class HookIdentityGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cosg-hooks-")
        root = Path(self.temporary.name).resolve()
        self.other_repo = root / "some-project"
        self.other_repo.mkdir(parents=True)
        self.denials = root / "denials.jsonl"
        self.notifications = root / "notifications.jsonl"
        self.environment = patch.dict(os.environ, {
            "COSG_DENY_LOG_FILE": str(self.denials),
            "COSG_NOTIFICATION_LOG_FILE": str(self.notifications),
        })
        self.environment.start()

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def test_non_chief_of_staff_session_is_never_touched(self) -> None:
        with patch.dict(os.environ, {"MOSAICO_AGENT": "orbit-builder"}, clear=False):
            output = hook_output(git_push_payload(self.other_repo))
        self.assertEqual(output, "")
        self.assertEqual(read_jsonl(self.denials), [])

    def test_session_with_no_identity_signal_is_never_touched(self) -> None:
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("MOSAICO_AGENT", None)
            os.environ.pop("CLAUDE_CODE_AGENT", None)
            output = hook_output(git_push_payload(self.other_repo))
        self.assertEqual(output, "")

    def test_chief_of_staff_session_git_push_is_denied_and_logged(self) -> None:
        with patch.dict(os.environ, {"MOSAICO_AGENT": "chief-of-staff"}, clear=False):
            output = hook_output(git_push_payload(self.other_repo))
        decision = json.loads(output)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn("git push", decision["permissionDecisionReason"])

        records = read_jsonl(self.denials)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["session_id"], "cos-session-1")

        notices = read_jsonl(self.notifications)
        self.assertEqual(len(notices), 1)

    def test_chief_of_staff_session_git_status_is_allowed(self) -> None:
        payload = {
            "cwd": str(self.other_repo),
            "session_id": "cos-session-1",
            "tool_name": "Bash",
            "tool_input": {"command": "git status"},
        }
        with patch.dict(os.environ, {"MOSAICO_AGENT": "chief-of-staff"}, clear=False):
            output = hook_output(payload)
        self.assertEqual(output, "")
        self.assertEqual(read_jsonl(self.denials), [])

    def test_claude_code_agent_fallback_is_honored_when_mosaico_agent_unset(self) -> None:
        with patch.dict(os.environ, {"CLAUDE_CODE_AGENT": "chief-of-staff"}, clear=False):
            os.environ.pop("MOSAICO_AGENT", None)
            output = hook_output(git_push_payload(self.other_repo))
        decision = json.loads(output)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")

    def test_harness_permission_events_are_not_our_business(self) -> None:
        with patch.dict(os.environ, {"MOSAICO_AGENT": "chief-of-staff"}, clear=False):
            output = io.StringIO()
            with redirect_stdout(output):
                run_harness_hook("permission-request", git_push_payload(self.other_repo))
        self.assertEqual(output.getvalue().strip(), "")
        self.assertEqual(read_jsonl(self.denials), [])


def git_push_payload(cwd: Path) -> dict[str, object]:
    return {
        "cwd": str(cwd),
        "session_id": "cos-session-1",
        "tool_name": "Bash",
        "tool_input": {"command": "git push origin main"},
    }


def hook_output(payload: dict[str, object]) -> str:
    output = io.StringIO()
    with redirect_stdout(output):
        run_harness_hook("pre-tool-use", payload)
    return output.getvalue().strip()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


if __name__ == "__main__":
    unittest.main()

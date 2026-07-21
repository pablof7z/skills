"""Tests that base access is granted only by an explicit request, never by a write."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.cli import main  # noqa: E402
from worktreeguard.hooks import run_harness_hook  # noqa: E402
from worktreeguard.storage import (  # noqa: E402
    active_grants, auto_grant_base_edits_enabled, load_state,
    set_auto_grant_base_edits,
)


class BaseAccessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-auto-grant-")
        root = Path(self.temporary.name).resolve()
        self.base = root / "repo"
        self.state = root / "state.json"
        self.notifications = root / "notifications.jsonl"
        self.denials = root / "denials.jsonl"
        run(["git", "init", "-q", "-b", "main", str(self.base)])
        run(["git", "config", "user.email", "probe@example.com"], cwd=self.base)
        run(["git", "config", "user.name", "Probe"], cwd=self.base)
        (self.base / "tracked.txt").write_text("test\n", encoding="utf-8")
        run(["git", "add", "tracked.txt"], cwd=self.base)
        run(["git", "commit", "-q", "-m", "initial"], cwd=self.base)
        self.environment = patch.dict(os.environ, {
            "WTG_STATE_FILE": str(self.state),
            "WTG_NOTIFICATION_LOG_FILE": str(self.notifications),
            "WTG_DENY_LOG_FILE": str(self.denials),
            "WTG_SESSION_ID": "session-one",
        })
        self.environment.start()

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def test_existing_state_keeps_only_session_bound_grants(self) -> None:
        expires_at = int(time.time()) + 300
        self.state.write_text(
            json.dumps({"version": 3, "grants": [
                {
                    "id": "session", "scope": "session",
                    "session_id": "s", "expires_at": expires_at,
                },
                {
                    "id": "once", "scope": "once",
                    "session_id": "s", "expires_at": expires_at,
                },
                {"id": "unbound", "scope": "session", "expires_at": expires_at},
            ]}),
            encoding="utf-8",
        )
        state = load_state()
        self.assertEqual(state["version"], 4)
        self.assertEqual([grant["id"] for grant in state["grants"]], ["session"])
        self.assertTrue(auto_grant_base_edits_enabled())

    def test_unrequested_base_edit_is_denied_even_with_auto_grant_on(self) -> None:
        self.assertTrue(auto_grant_base_edits_enabled())
        output = json.loads(hook_output("pre-tool-use", native_payload(self.base, "session-one")))
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(len(read_jsonl(self.denials)), 1)
        self.assertEqual(active_grants(), [])
        self.assertFalse(self.notifications.exists())

    def test_harness_permission_events_are_not_wtg_business(self) -> None:
        self.assertEqual(hook_output("permission-request", native_payload(self.base, "s")), "")
        self.assertEqual(read_jsonl(self.denials), [])

    def test_request_auto_grants_and_notifies_then_edits_pass(self) -> None:
        self.assertEqual(request_access(self.base, "user asked for a base edit"), 0)
        notices = read_jsonl(self.notifications)
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0]["base_path"], str(self.base))
        self.assertIn("requested and was auto-granted", notices[0]["message"])
        self.assertEqual(len(active_grants()), 1)
        self.assertEqual(active_grants()[0]["scope"], "session")
        self.assertEqual(active_grants()[0]["session_id"], "session-one")
        self.assertEqual(hook_output("pre-tool-use", native_payload(self.base, "session-one")), "")
        self.assertEqual(hook_output("pre-tool-use", native_payload(self.base, "session-one")), "")

    def test_granted_session_also_unblocks_git(self) -> None:
        self.assertEqual(request_access(self.base, "rebasing on purpose"), 0)
        self.assertEqual(hook_output("pre-tool-use", git_payload(self.base, "session-one")), "")

    def test_request_with_auto_grant_off_prompts_and_can_be_denied(self) -> None:
        set_auto_grant_base_edits(False)
        with patch.dict(os.environ, {"WTG_APPROVAL_RESPONSE": "deny"}):
            self.assertEqual(request_access(self.base, "should be refused"), 1)
        self.assertEqual(active_grants(), [])
        self.assertFalse(self.notifications.exists())
        output = json.loads(hook_output("pre-tool-use", native_payload(self.base, "session-one")))
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_one_time_approval_response_is_rejected(self) -> None:
        set_auto_grant_base_edits(False)
        with patch.dict(os.environ, {"WTG_APPROVAL_RESPONSE": "once"}):
            self.assertEqual(request_access(self.base, "one command only"), 1)
        self.assertEqual(active_grants(), [])

    def test_scope_option_is_not_accepted(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main([
                "request-base-access", "--repo", str(self.base),
                "--reason", "one command only", "--scope", "once",
            ])

    def test_codex_thread_id_binds_request_when_override_is_absent(self) -> None:
        with patch.dict(os.environ, {
            "WTG_SESSION_ID": "", "CLAUDE_CODE_SESSION_ID": "", "CODEX_THREAD_ID": "codex-session",
        }):
            self.assertEqual(request_access(self.base, "codex base edit"), 0)
        self.assertEqual(active_grants()[0]["session_id"], "codex-session")

    def test_claude_code_session_id_binds_request_when_override_is_absent(self) -> None:
        with patch.dict(os.environ, {
            "WTG_SESSION_ID": "", "CLAUDE_CODE_SESSION_ID": "claude-session",
            "CODEX_THREAD_ID": "",
        }):
            self.assertEqual(request_access(self.base, "claude base edit"), 0)
        self.assertEqual(active_grants()[0]["session_id"], "claude-session")

    def test_request_without_harness_session_is_refused(self) -> None:
        with patch.dict(os.environ, {
            "WTG_SESSION_ID": "", "CLAUDE_CODE_SESSION_ID": "", "CODEX_THREAD_ID": "",
        }), redirect_stderr(io.StringIO()):
            self.assertEqual(request_access(self.base, "unbound edit"), 1)
        self.assertEqual(active_grants(), [])

    def test_grant_does_not_leak_to_another_session(self) -> None:
        self.assertEqual(request_access(self.base, "scoped to session-one"), 0)
        output = json.loads(hook_output("pre-tool-use", native_payload(self.base, "session-two")))
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")


def native_payload(base: Path, session_id: str) -> dict[str, object]:
    return {
        "cwd": str(base),
        "session_id": session_id,
        "tool_name": "Edit",
        "tool_input": {"file_path": str(base / "tracked.txt")},
    }


def git_payload(base: Path, session_id: str) -> dict[str, object]:
    return {
        "cwd": str(base),
        "session_id": session_id,
        "tool_name": "Bash",
        "tool_input": {"command": "git reset --hard"},
    }


def request_access(base: Path, reason: str) -> int:
    with redirect_stdout(io.StringIO()):
        return main(["request-base-access", "--repo", str(base), "--reason", reason])


def hook_output(event: str, payload: dict[str, object]) -> str:
    output = io.StringIO()
    with redirect_stdout(output):
        run_harness_hook(event, payload)
    return output.getvalue().strip()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()

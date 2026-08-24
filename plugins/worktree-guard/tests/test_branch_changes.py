"""Tests for branch-change detection and the branchChanges approval policy."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.cli import main  # noqa: E402
from worktreeguard.hooks import run_harness_hook  # noqa: E402
from worktreeguard.policy import blocked_git_operation  # noqa: E402
from worktreeguard.storage import (  # noqa: E402
    active_grants, create_grant, read_config, write_config,
)


class BranchChangeDetectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-branch-")
        root = Path(self.temporary.name).resolve()
        self.base = root / "repo"
        run(["git", "init", "-q", "-b", "main", str(self.base)])
        run(["git", "config", "user.email", "probe@example.com"], cwd=self.base)
        run(["git", "config", "user.name", "Probe"], cwd=self.base)
        (self.base / "tracked.txt").write_text("test\n", encoding="utf-8")
        run(["git", "add", "tracked.txt"], cwd=self.base)
        run(["git", "commit", "-q", "-m", "initial"], cwd=self.base)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def detected(self, command: str) -> bool | None:
        op = blocked_git_operation(command, self.base)
        if op is None:
            return None
        return op.branch_change

    def test_switch_always_branch_change(self) -> None:
        self.assertTrue(self.detected("git switch main"))
        self.assertTrue(self.detected("git switch -c new"))

    def test_checkout_new_branch_is_branch_change(self) -> None:
        self.assertTrue(self.detected("git checkout -b feature"))
        self.assertTrue(self.detected("git checkout -B feature"))

    def test_checkout_existing_branch_is_branch_change(self) -> None:
        self.assertTrue(self.detected("git checkout main"))

    def test_path_restore_is_not_branch_change(self) -> None:
        self.assertFalse(self.detected("git checkout -- tracked.txt"))
        self.assertFalse(self.detected("git checkout tracked.txt"))
        self.assertFalse(self.detected("git checkout main -- tracked.txt"))

    def test_non_checkout_commands_are_not_branch_change(self) -> None:
        self.assertFalse(self.detected("git reset --hard"))
        self.assertFalse(self.detected("git clean -fd"))


class BranchPolicyHookTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-branch-policy-")
        root = Path(self.temporary.name).resolve()
        self.base = root / "repo"
        self.state = root / "state.json"
        self.denials = root / "denials.jsonl"
        run(["git", "init", "-q", "-b", "main", str(self.base)])
        run(["git", "config", "user.email", "probe@example.com"], cwd=self.base)
        run(["git", "config", "user.name", "Probe"], cwd=self.base)
        (self.base / "tracked.txt").write_text("test\n", encoding="utf-8")
        run(["git", "add", "tracked.txt"], cwd=self.base)
        run(["git", "commit", "-q", "-m", "initial"], cwd=self.base)
        self.env = patch.dict(os.environ, {
            "WTG_STATE_FILE": str(self.state),
            "WTG_DENY_LOG_FILE": str(self.denials),
            "WTG_SESSION_ID": "branch-session",
        })
        self.env.start()

    def tearDown(self) -> None:
        self.env.stop()
        self.temporary.cleanup()

    def switch_payload(self) -> dict[str, object]:
        return {
            "cwd": str(self.base), "session_id": "branch-session",
            "tool_name": "Bash", "tool_input": {"command": "git switch main"},
        }

    def reset_payload(self) -> dict[str, object]:
        return {
            "cwd": str(self.base), "session_id": "branch-session",
            "tool_name": "Bash", "tool_input": {"command": "git reset --hard"},
        }

    def hook(self, payload) -> str:
        out = io.StringIO()
        with redirect_stdout(out):
            run_harness_hook("pre-tool-use", payload, harness="codex")
        return out.getvalue().strip()

    def test_block_mode_denies_switch_even_with_general_grant(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "block"})
        create_grant(base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session")
        out = json.loads(self.hook(self.switch_payload()))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("automatically denied", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_block_mode_still_allows_non_branch_ops_with_grant(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "block"})
        create_grant(base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session")
        self.assertEqual(self.hook(self.reset_payload()), "")

    def test_manual_mode_denies_switch_with_auto_grant(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "manual"})
        create_grant(base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session")
        out = json.loads(self.hook(self.switch_payload()))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("auto-approval is disabled for branch changes", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_manual_mode_allows_switch_with_branch_change_grant(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "manual"})
        create_grant(base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session", branch_change=True)
        self.assertEqual(self.hook(self.switch_payload()), "")

    def test_manual_mode_branch_grant_does_not_leak_beyond_session(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "manual"})
        create_grant(base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session", branch_change=True)
        other = dict(self.switch_payload(), session_id="other-session")
        out = json.loads(self.hook(other))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_follow_mode_allows_switch_with_general_grant(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "follow"})
        create_grant(base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session")
        self.assertEqual(self.hook(self.switch_payload()), "")


class RequestBranchAccessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-branch-req-")
        root = Path(self.temporary.name).resolve()
        self.base = root / "repo"
        self.state = root / "state.json"
        self.requests = root / "requests.jsonl"
        run(["git", "init", "-q", "-b", "main", str(self.base)])
        run(["git", "config", "user.email", "probe@example.com"], cwd=self.base)
        run(["git", "config", "user.name", "Probe"], cwd=self.base)
        (self.base / "tracked.txt").write_text("test\n", encoding="utf-8")
        run(["git", "add", "tracked.txt"], cwd=self.base)
        run(["git", "commit", "-q", "-m", "initial"], cwd=self.base)
        self.env = patch.dict(os.environ, {
            "WTG_STATE_FILE": str(self.state),
            "WTG_REQUEST_LOG_FILE": str(self.requests),
            "WTG_SESSION_ID": "req-session",
        })
        self.env.start()

    def tearDown(self) -> None:
        self.env.stop()
        self.temporary.cleanup()

    def request_branch(self, config: dict) -> int:
        write_config(self.base, config)
        with redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
            return main([
                "request-base-access", "--repo", str(self.base),
                "--branch-change", "--reason", "switching",
            ])

    def test_block_mode_auto_denies_branch_request(self) -> None:
        self.assertEqual(self.request_branch(
            {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "block"}), 1)
        self.assertEqual(active_grants(), [])

    def test_manual_mode_forces_human_approval_even_with_bypass(self) -> None:
        with patch.dict(os.environ, {"WTG_APPROVAL_RESPONSE": "deny"}):
            self.assertEqual(self.request_branch(
                {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "manual"}), 1)
        self.assertEqual(active_grants(), [])

    def test_manual_mode_human_approval_grants_branch_change(self) -> None:
        with patch.dict(os.environ, {"WTG_APPROVAL_RESPONSE": "session"}):
            self.assertEqual(self.request_branch(
                {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "manual"}), 0)
        self.assertTrue(active_grants())
        self.assertTrue(active_grants()[0]["branch_change"])

    def test_follow_mode_with_bypass_auto_grants_branch_change(self) -> None:
        self.assertEqual(self.request_branch(
            {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "follow"}), 0)
        self.assertTrue(active_grants()[0]["branch_change"])


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
"""Tests for branch-change detection and the branchChanges group's policy."""

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

    def group(self, command: str) -> str | None:
        op = blocked_git_operation(command, self.base)
        return None if op is None else op.group

    def test_switch_is_branch_changes_group(self) -> None:
        self.assertEqual(self.group("git switch main"), "branchChanges")
        self.assertEqual(self.group("git switch -c new"), "branchChanges")

    def test_checkout_new_branch_is_branch_changes_group(self) -> None:
        self.assertEqual(self.group("git checkout -b feature"), "branchChanges")
        self.assertEqual(self.group("git checkout -B feature"), "branchChanges")

    def test_checkout_existing_branch_is_branch_changes_group(self) -> None:
        self.assertEqual(self.group("git checkout main"), "branchChanges")

    def test_path_restore_is_discard_group_not_branch_changes(self) -> None:
        self.assertEqual(self.group("git checkout -- tracked.txt"), "discard")
        self.assertEqual(self.group("git checkout tracked.txt"), "discard")
        self.assertEqual(self.group("git checkout main -- tracked.txt"), "discard")

    def test_reset_clean_rebase_restore_are_discard_group(self) -> None:
        self.assertEqual(self.group("git reset --hard"), "discard")
        self.assertEqual(self.group("git clean -fd"), "discard")
        self.assertEqual(self.group("git rebase main"), "discard")
        self.assertEqual(self.group("git restore tracked.txt"), "discard")

    def test_stash_is_its_own_group_not_discard(self) -> None:
        # Deliberately not folded into "discard": silently displacing an agent's own
        # uncommitted work without it knowing is a distinct risk, not a lesser one.
        self.assertEqual(self.group("git stash"), "stash")
        self.assertEqual(self.group("git stash pop"), "stash")


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

    def test_bypass_none_denies_switch_even_with_general_grant(self) -> None:
        write_config(self.base, {"branchChanges": {"bypass": "none"}})
        create_grant(base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session")
        out = json.loads(self.hook(self.switch_payload()))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("automatically denied", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_bypass_none_on_branch_changes_still_allows_discard_with_grant(self) -> None:
        # Groups are independent: tightening branchChanges doesn't touch discard.
        write_config(self.base, {"branchChanges": {"bypass": "none"}})
        create_grant(base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session")
        self.assertEqual(self.hook(self.reset_payload()), "")

    def test_bypass_manual_denies_switch_with_general_auto_grant(self) -> None:
        write_config(self.base, {"branchChanges": {"bypass": "manual"}})
        create_grant(base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session")
        out = json.loads(self.hook(self.switch_payload()))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("auto-approval is disabled for this group", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_bypass_manual_allows_switch_with_group_tagged_grant(self) -> None:
        write_config(self.base, {"branchChanges": {"bypass": "manual"}})
        create_grant(
            base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session",
            group="branchChanges",
        )
        self.assertEqual(self.hook(self.switch_payload()), "")

    def test_bypass_manual_group_grant_does_not_cover_a_different_group(self) -> None:
        write_config(self.base, {"branchChanges": {"bypass": "manual"}})
        create_grant(
            base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session",
            group="discard",
        )
        out = json.loads(self.hook(self.switch_payload()))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_bypass_manual_grant_does_not_leak_beyond_session(self) -> None:
        write_config(self.base, {"branchChanges": {"bypass": "manual"}})
        create_grant(
            base_path=self.base, reason="r", ttl_seconds=300, session_id="branch-session",
            group="branchChanges",
        )
        other = dict(self.switch_payload(), session_id="other-session")
        out = json.loads(self.hook(other))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_bypass_auto_allows_switch_with_general_grant(self) -> None:
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

    def test_bypass_none_auto_denies_branch_request(self) -> None:
        self.assertEqual(self.request_branch({"branchChanges": {"bypass": "none"}}), 1)
        self.assertEqual(active_grants(), [])

    def test_bypass_manual_forces_human_approval(self) -> None:
        with patch.dict(os.environ, {"WTG_APPROVAL_RESPONSE": "deny"}):
            self.assertEqual(self.request_branch({"branchChanges": {"bypass": "manual"}}), 1)
        self.assertEqual(active_grants(), [])

    def test_bypass_manual_human_approval_grants_branch_change(self) -> None:
        with patch.dict(os.environ, {"WTG_APPROVAL_RESPONSE": "session"}):
            self.assertEqual(self.request_branch({"branchChanges": {"bypass": "manual"}}), 0)
        self.assertTrue(active_grants())
        self.assertEqual(active_grants()[0]["group"], "branchChanges")

    def test_bypass_auto_grants_branch_change(self) -> None:
        self.assertEqual(self.request_branch({}), 0)
        self.assertEqual(active_grants()[0]["group"], "branchChanges")

    def test_group_flag_is_equivalent_to_branch_change_alias(self) -> None:
        with redirect_stdout(io.StringIO()):
            code = main([
                "request-base-access", "--repo", str(self.base),
                "--group", "branchChanges", "--reason", "switching",
            ])
        self.assertEqual(code, 0)
        self.assertEqual(active_grants()[0]["group"], "branchChanges")

    def test_group_and_branch_change_are_mutually_exclusive(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main([
                "request-base-access", "--repo", str(self.base),
                "--group", "writes", "--branch-change", "--reason", "x",
            ])

    def test_group_is_required(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main(["request-base-access", "--repo", str(self.base), "--reason", "x"])


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()

"""Focused tests for ChiefOfStaffGuard's explicit policy boundary.

Cases are drawn directly from the 2026-07-25 incidents in
agent-home/chief-of-staff/workflows/agent-coordination-standards.md
(section 5): (1) git conflict resolution/merges/pushes across project repos,
(2) merging a project PR itself on green CI alone, and (3) personally
debugging/fixing a broken TTS29 daemon (killing/restarting processes,
clearing local state, publishing raw events to a relay).
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from chiefofstaffguard.policy import (  # noqa: E402
    BlockedFileOperation,
    BlockedShellOperation,
    blocked_operation,
    blocked_shell_operation,
)


class ChiefOfStaffGuardPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cosg-test-")
        root = Path(self.temporary.name).resolve()
        self.tracking_home = root / "everything"
        self.agent_home = root / "agents-home" / "chief-of-staff"
        self.other_repo = root / "some-project"
        self.tracking_home.mkdir(parents=True)
        self.agent_home.mkdir(parents=True)
        self.other_repo.mkdir(parents=True)
        self.environment = patch.dict(os.environ, {
            "COSG_TRACKING_REPO_HOME": str(self.tracking_home),
            "COSG_AGENT_HOME": str(self.agent_home),
        })
        self.environment.start()

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    # --- read-only inspection: always allowed --------------------------

    def test_read_only_git_forms_are_allowed(self) -> None:
        commands = (
            "git status", "git log", "git diff", "git show",
            "git branch", "git branch --list", "git branch -a",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(blocked_shell_operation(command, self.other_repo))

    def test_read_only_inspection_tools_are_allowed(self) -> None:
        commands = (
            "ls -la", "cat README.md", "find . -name '*.py'", "grep -r TODO .",
            "ps aux", "lsof -i", "curl https://example.com/status",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(blocked_shell_operation(command, self.other_repo))

    def test_gh_read_forms_are_allowed(self) -> None:
        commands = (
            "gh pr view 1", "gh pr list", "gh pr checks 1", "gh pr diff 1",
            "gh issue view 2", "gh issue list", "gh api repos/x/y/pulls",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(blocked_shell_operation(command, self.other_repo))

    def test_gh_handoff_forms_are_allowed(self) -> None:
        # Filing/opening work for someone else to pick up or review is
        # orchestration, not implementation. A deliberate judgment call --
        # see README "gh pr create is a genuine gray area".
        commands = (
            "gh pr create --title x --body y",
            "gh pr comment 1 --body hi",
            "gh issue create --title x --body y",
            "gh issue comment 2 --body hi",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(blocked_shell_operation(command, self.other_repo))

    def test_all_mosaico_subcommands_are_allowed(self) -> None:
        commands = (
            "mosaico dispatch builder@claude --workspace ws --channel /ch --message hi",
            "mosaico channel send /ch hi",
            "mosaico session",
            "mosaico my session",
            "mosaico doctor",
            "mosaico agents list",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(blocked_shell_operation(command, self.other_repo))

    # --- incident 1: git conflict resolution, merges, pushes ------------

    def test_git_write_operations_are_blocked(self) -> None:
        commands = (
            "git merge main", "git push origin main", "git rebase origin/main",
            "git reset --hard", "git checkout -b fix", "git branch -d old",
            "git worktree add ../x", "git commit -m resolved", "git add .",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertIsInstance(blocked_shell_operation(command, self.other_repo), BlockedShellOperation)

    # --- incident 2: merged a project PR itself on green CI alone -------

    def test_gh_pr_merge_is_blocked(self) -> None:
        blocked = blocked_shell_operation("gh pr merge 42 --squash", self.other_repo)
        self.assertIsInstance(blocked, BlockedShellOperation)

    def test_gh_pr_review_edit_and_close_are_blocked(self) -> None:
        commands = ("gh pr review 42 --approve", "gh pr edit 42 --add-label x", "gh pr close 42")
        for command in commands:
            with self.subTest(command=command):
                self.assertIsInstance(blocked_shell_operation(command, self.other_repo), BlockedShellOperation)

    # --- incident 3: personally debugged/fixed the TTS29 daemon ---------

    def test_kill_and_pkill_are_blocked(self) -> None:
        for command in ("kill -9 4821", "pkill -f tts29d"):
            with self.subTest(command=command):
                self.assertIsInstance(blocked_shell_operation(command, self.other_repo), BlockedShellOperation)

    def test_launchctl_and_systemctl_are_blocked(self) -> None:
        commands = ("launchctl kickstart -k gui/501/com.tts29.daemon", "systemctl restart tts29")
        for command in commands:
            with self.subTest(command=command):
                self.assertIsInstance(blocked_shell_operation(command, self.other_repo), BlockedShellOperation)

    def test_clearing_local_daemon_state_outside_home_is_blocked(self) -> None:
        target = self.other_repo / "state.json"
        blocked = blocked_shell_operation(f"rm {target}", self.other_repo)
        self.assertIsInstance(blocked, BlockedShellOperation)

    def test_publishing_raw_events_to_a_relay_is_blocked(self) -> None:
        blocked = blocked_shell_operation(
            'curl -X POST https://relay.example.com/publish -d \'{"kind":1}\'', self.other_repo,
        )
        self.assertIsInstance(blocked, BlockedShellOperation)

    # --- self-management carve-out (tracking-repo home / agent home) ----

    def test_writes_inside_tracking_repo_home_are_allowed(self) -> None:
        commands = (
            f"rm {self.tracking_home / 'scratch.txt'}",
            f"cp {self.tracking_home / 'a.md'} {self.tracking_home / 'b.md'}",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(blocked_shell_operation(command, self.tracking_home))

    def test_writes_inside_agent_home_are_allowed(self) -> None:
        self.assertIsNone(
            blocked_shell_operation(f"rm {self.agent_home / 'scratch.txt'}", self.agent_home)
        )

    def test_native_edit_inside_tracking_home_is_allowed(self) -> None:
        operation = native("Edit", file_path=str(self.tracking_home / "workflows" / "notes.md"))
        self.assertIsNone(blocked_operation(operation, self.tracking_home))

    def test_native_edit_outside_home_is_blocked(self) -> None:
        operation = native("Edit", file_path=str(self.other_repo / "main.py"))
        blocked = blocked_operation(operation, self.other_repo)
        self.assertIsInstance(blocked, BlockedFileOperation)

    def test_mv_that_moves_a_file_out_of_home_is_blocked(self) -> None:
        blocked = blocked_shell_operation(
            f"mv {self.tracking_home / 'a.md'} {self.other_repo / 'a.md'}", self.tracking_home,
        )
        self.assertIsInstance(blocked, BlockedShellOperation)

    # --- output redirection and general default-deny --------------------

    def test_redirection_outside_home_is_blocked(self) -> None:
        blocked = blocked_shell_operation(f"echo hi > {self.other_repo / 'out.txt'}", self.other_repo)
        self.assertIsInstance(blocked, BlockedShellOperation)

    def test_redirection_inside_home_is_allowed(self) -> None:
        self.assertIsNone(
            blocked_shell_operation(f"echo hi > {self.tracking_home / 'out.txt'}", self.tracking_home)
        )

    def test_unlisted_interpreters_default_deny(self) -> None:
        commands = ("python3 -c 'print(1)'", "node -e 'console.log(1)'", "ruby -e 'puts 1'")
        for command in commands:
            with self.subTest(command=command):
                self.assertIsInstance(blocked_shell_operation(command, self.other_repo), BlockedShellOperation)

    def test_sed_in_place_and_find_delete_are_blocked(self) -> None:
        commands = (f"sed -i '' 's/a/b/' {self.other_repo / 'f.txt'}", f"find {self.other_repo} -name '*.tmp' -delete")
        for command in commands:
            with self.subTest(command=command):
                self.assertIsInstance(blocked_shell_operation(command, self.other_repo), BlockedShellOperation)

    def test_compound_command_blocks_if_any_segment_is_blocked(self) -> None:
        blocked = blocked_shell_operation("git status && git push origin main", self.other_repo)
        self.assertIsInstance(blocked, BlockedShellOperation)
        self.assertEqual(blocked.program, "git")

    def test_cd_then_blocked_git_is_still_blocked(self) -> None:
        blocked = blocked_shell_operation(f"cd {self.other_repo} && git commit -m x", Path("/tmp"))
        self.assertIsInstance(blocked, BlockedShellOperation)

    def test_non_shell_non_write_tools_are_outside_policy(self) -> None:
        operation = {"tool_name": "Grep", "command": "", "tool_input": {"pattern": "x"}}
        self.assertIsNone(blocked_operation(operation, self.other_repo))


def native(tool_name: str, **tool_input: str) -> dict[str, object]:
    return {"tool_name": tool_name, "command": "", "tool_input": tool_input}


if __name__ == "__main__":
    unittest.main()

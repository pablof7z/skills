"""Focused tests for WorktreeGuard's explicit policy boundary."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.core import BLOCKED_GIT_COMMANDS  # noqa: E402
from worktreeguard.policy import blocked_git_operation  # noqa: E402


class WorktreeGuardPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-test-")
        root = Path(self.temporary.name)
        self.base = root / "repo"
        self.linked = root / "linked"
        self.outside = root
        run(["git", "init", "-q", "-b", "main", str(self.base)])
        run(["git", "config", "user.email", "probe@example.com"], cwd=self.base)
        run(["git", "config", "user.name", "Probe"], cwd=self.base)
        (self.base / "tracked.txt").write_text("test\n", encoding="utf-8")
        run(["git", "add", "tracked.txt"], cwd=self.base)
        run(["git", "commit", "-q", "-m", "initial"], cwd=self.base)
        run(["git", "worktree", "add", "-q", "-b", "linked", str(self.linked)], cwd=self.base)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_exact_denylist_is_blocked_in_base(self) -> None:
        for command in BLOCKED_GIT_COMMANDS:
            with self.subTest(command=command):
                blocked = blocked_git_operation(f"git {command}", self.base)
                self.assertIsNotNone(blocked)
                self.assertEqual(blocked.subcommand, command)

    def test_exact_denylist_is_allowed_in_linked_worktree(self) -> None:
        for command in BLOCKED_GIT_COMMANDS:
            with self.subTest(command=command):
                self.assertIsNone(blocked_git_operation(f"git {command}", self.linked))

    def test_everything_else_is_outside_policy(self) -> None:
        commands = (
            "git add .", "git commit -m test", "git fetch", "git merge main",
            "git pull", "git worktree list", "printf hello", "git 'reset",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(blocked_git_operation(command, self.base))

    def test_common_working_directory_forms(self) -> None:
        self.assertIsNotNone(
            blocked_git_operation(f"git -C {self.base} reset --hard", self.outside)
        )
        self.assertIsNotNone(
            blocked_git_operation(f"cd {self.base} && git switch main", self.outside)
        )
        self.assertIsNone(
            blocked_git_operation(f"git -C {self.linked} reset --hard", self.base)
        )


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()

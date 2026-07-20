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
from worktreeguard.policy import blocked_git_operation, blocked_operation  # noqa: E402


class WorktreeGuardPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-test-")
        root = Path(self.temporary.name).resolve()
        self.base = root / "repo"
        self.linked = root / "linked"
        self.outside = root
        self.external = root / "external.txt"
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
            "git pull", "git worktree list", "printf hello", "rm tracked.txt",
            "python3 -c 'open(\"new.txt\", \"w\").write(\"x\")'", "git 'reset",
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

    def test_native_edit_tools_are_blocked_in_base(self) -> None:
        cases = (
            native("Edit", file_path=str(self.base / "tracked.txt")),
            native("Write", path=str(self.base / "new.txt")),
            native("MultiEdit", file_path="tracked.txt"),
            native("NotebookEdit", notebook_path=str(self.base / "notes.ipynb")),
        )
        for operation in cases:
            with self.subTest(tool=operation["tool_name"]):
                blocked = blocked_operation(operation, self.base)
                self.assertIsNotNone(blocked)
                self.assertEqual(blocked.base_path, self.base)

    def test_apply_patch_targets_are_blocked_in_base(self) -> None:
        patch = "\n".join((
            "*** Begin Patch",
            "*** Update File: tracked.txt",
            f"*** Move to: {self.base / 'renamed.txt'}",
            "*** End Patch",
        ))
        blocked = blocked_operation(native("apply_patch", patch=patch), self.base)
        self.assertIsNotNone(blocked)
        self.assertEqual(blocked.target, self.base / "tracked.txt")

    def test_apply_patch_accepts_raw_harness_input(self) -> None:
        operation = {
            "tool_name": "apply_patch",
            "command": "",
            "tool_input": {},
            "raw_input": "*** Begin Patch\n*** Add File: raw.txt\n*** End Patch",
        }
        self.assertIsNotNone(blocked_operation(operation, self.base))

    def test_native_writes_are_allowed_outside_base(self) -> None:
        cases = (
            (native("Edit", file_path=str(self.linked / "tracked.txt")), self.base),
            (native("Write", path=str(self.external)), self.base),
            (native("apply_patch", patch="*** Add File: new.txt"), self.linked),
        )
        for operation, cwd in cases:
            with self.subTest(tool=operation["tool_name"], cwd=cwd):
                self.assertIsNone(blocked_operation(operation, cwd))

    def test_native_write_without_target_uses_checkout_context(self) -> None:
        self.assertIsNotNone(blocked_operation(native("Write"), self.base))
        self.assertIsNone(blocked_operation(native("Write"), self.linked))

    def test_non_native_tool_is_outside_file_write_policy(self) -> None:
        operation = native("mcp__server__write_file", path=str(self.base / "new.txt"))
        self.assertIsNone(blocked_operation(operation, self.base))


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


def native(tool_name: str, **tool_input: str) -> dict[str, object]:
    return {"tool_name": tool_name, "command": "", "tool_input": tool_input}


if __name__ == "__main__":
    unittest.main()

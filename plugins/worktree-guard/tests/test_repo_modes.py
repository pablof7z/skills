"""Tests for per-repo guard-mode configuration (full | files-only | off)."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.cli import main  # noqa: E402
from worktreeguard.policy import blocked_git_operation, blocked_operation  # noqa: E402
from worktreeguard.storage import repo_mode, set_repo_mode  # noqa: E402


class RepoModeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-repo-modes-")
        root = Path(self.temporary.name).resolve()
        self.base = root / "repo"
        self.linked = root / "linked"
        self.state = root / "state.json"
        run(["git", "init", "-q", "-b", "main", str(self.base)])
        run(["git", "config", "user.email", "probe@example.com"], cwd=self.base)
        run(["git", "config", "user.name", "Probe"], cwd=self.base)
        (self.base / "tracked.txt").write_text("test\n", encoding="utf-8")
        run(["git", "add", "tracked.txt"], cwd=self.base)
        run(["git", "commit", "-q", "-m", "initial"], cwd=self.base)
        run(["git", "worktree", "add", "-q", "-b", "linked", str(self.linked)], cwd=self.base)
        self.environment = patch.dict(os.environ, {"WTG_STATE_FILE": str(self.state)})
        self.environment.start()

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def test_default_mode_is_full_and_blocks(self) -> None:
        self.assertEqual(repo_mode(self.base), "full")
        self.assertIsNotNone(blocked_git_operation("git reset --hard", self.base))
        self.assertIsNotNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_files_only_disables_git_block_but_keeps_file_block(self) -> None:
        set_repo_mode(self.base, "files-only")
        self.assertIsNone(blocked_git_operation("git reset --hard", self.base))
        self.assertIsNotNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_off_disables_both_blocks(self) -> None:
        set_repo_mode(self.base, "off")
        self.assertIsNone(blocked_git_operation("git reset --hard", self.base))
        self.assertIsNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_linked_worktree_unaffected_by_mode(self) -> None:
        for mode in ("full", "off"):
            set_repo_mode(self.base, mode)
            with self.subTest(mode=mode):
                self.assertIsNone(blocked_git_operation("git reset --hard", self.linked))
                self.assertIsNone(
                    blocked_operation(native("Write", path=str(self.linked / "new.txt")), self.linked)
                )

    def test_repo_mode_defaults_and_round_trips(self) -> None:
        self.assertEqual(repo_mode(self.base), "full")
        set_repo_mode(self.base, "files-only")
        self.assertEqual(repo_mode(self.base), "files-only")
        set_repo_mode(self.base, "off")
        self.assertEqual(repo_mode(self.base), "off")

    def test_invalid_stored_mode_is_treated_as_full(self) -> None:
        self.state.parent.mkdir(parents=True, exist_ok=True)
        self.state.write_text(
            json.dumps({
                "version": 5,
                "grants": [],
                "preferences": {},
                "repo_modes": {str(self.base): "bogus"},
            }),
            encoding="utf-8",
        )
        self.assertEqual(repo_mode(self.base), "full")

    def test_set_repo_mode_rejects_invalid_value(self) -> None:
        with self.assertRaises(ValueError):
            set_repo_mode(self.base, "bogus")

    def test_cli_config_repo_sets_and_reads(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = main(["config", "repo", str(self.base), "files-only"])
        self.assertEqual(code, 0)
        self.assertIn(f"repo {self.base}: files-only", buffer.getvalue())

        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = main(["config", "repo", str(self.base)])
        self.assertEqual(code, 0)
        self.assertIn(f"repo {self.base}: files-only", buffer.getvalue())


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


def native(tool_name: str, **tool_input: str) -> dict[str, object]:
    return {"tool_name": tool_name, "command": "", "tool_input": tool_input}


if __name__ == "__main__":
    unittest.main()

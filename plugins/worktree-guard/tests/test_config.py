"""Tests for the per-repo ``.wtg.json`` configuration."""

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
from worktreeguard.policy import (  # noqa: E402
    blocked_git_operation, blocked_operation, warned_file_operation,
)
from worktreeguard.storage import (  # noqa: E402
    DEFAULT_CONFIG, config_path, read_config, repo_config, set_config_value, write_config,
)


class RepoConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-config-")
        root = Path(self.temporary.name).resolve()
        self.base = root / "repo"
        self.linked = root / "linked"
        run(["git", "init", "-q", "-b", "main", str(self.base)])
        run(["git", "config", "user.email", "probe@example.com"], cwd=self.base)
        run(["git", "config", "user.name", "Probe"], cwd=self.base)
        (self.base / "tracked.txt").write_text("test\n", encoding="utf-8")
        run(["git", "add", "tracked.txt"], cwd=self.base)
        run(["git", "commit", "-q", "-m", "initial"], cwd=self.base)
        run(["git", "worktree", "add", "-q", "-b", "linked", str(self.linked)], cwd=self.base)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_missing_config_defaults_to_enabled_block_bypass(self) -> None:
        config = repo_config(self.base)
        self.assertEqual(config, DEFAULT_CONFIG)
        self.assertEqual(config_path(self.base), self.base / ".wtg.json")

    def test_enabled_false_disables_everything(self) -> None:
        write_config(self.base, {"enabled": False, "writes": "block", "allowBypass": True})
        self.assertFalse(repo_config(self.base).enabled)
        self.assertIsNone(blocked_git_operation("git reset --hard", self.base))
        self.assertIsNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))
        self.assertIsNone(warned_file_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_writes_off_allows_writes_but_git_still_blocked(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "off", "allowBypass": True})
        self.assertIsNotNone(blocked_git_operation("git reset --hard", self.base))
        self.assertIsNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))
        self.assertIsNone(warned_file_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_writes_warn_warns_without_blocking(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "warn", "allowBypass": True})
        self.assertIsNotNone(blocked_git_operation("git reset --hard", self.base))
        self.assertIsNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))
        self.assertIsNotNone(warned_file_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_writes_block_blocks_writes(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "block", "allowBypass": True})
        self.assertIsNotNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))
        self.assertIsNone(warned_file_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_linked_worktree_is_always_unrestricted(self) -> None:
        for writes in ("block", "off", "warn"):
            with self.subTest(writes=writes):
                write_config(self.base, {"enabled": True, "writes": writes, "allowBypass": True})
                self.assertIsNone(blocked_git_operation("git reset --hard", self.linked))
                self.assertIsNone(blocked_operation(native("Write", path=str(self.linked / "new.txt")), self.linked))
                self.assertIsNone(warned_file_operation(native("Write", path=str(self.linked / "new.txt")), self.linked))

    def test_partial_config_merges_with_defaults_per_field(self) -> None:
        config_path(self.base).write_text(json.dumps({"writes": "warn"}), encoding="utf-8")
        config = repo_config(self.base)
        self.assertTrue(config.enabled)
        self.assertEqual(config.writes, "warn")
        self.assertTrue(config.allow_bypass)

    def test_invalid_writes_value_falls_back_to_block(self) -> None:
        config_path(self.base).write_text(json.dumps({"writes": "bogus"}), encoding="utf-8")
        self.assertEqual(repo_config(self.base).writes, "block")

    def test_malformed_config_falls_back_to_defaults(self) -> None:
        config_path(self.base).write_text("{not json", encoding="utf-8")
        self.assertEqual(repo_config(self.base), DEFAULT_CONFIG)

    def test_read_config_returns_serializable_mapping(self) -> None:
        write_config(self.base, {"enabled": True, "writes": "warn", "allowBypass": False})
        self.assertEqual(read_config(self.base), {"enabled": True, "writes": "warn", "allowBypass": False, "branchChanges": "follow"})

    def test_set_config_value_rejects_unknown_key(self) -> None:
        from worktreeguard.core import WorktreeGuardError
        with self.assertRaises(WorktreeGuardError):
            set_config_value(self.base, "bogus", "1")

    def test_set_config_value_rejects_invalid_writes(self) -> None:
        from worktreeguard.core import WorktreeGuardError
        with self.assertRaises(WorktreeGuardError):
            set_config_value(self.base, "writes", "bogus")

    def test_cli_config_show_prints_effective_defaults(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.assertEqual(main(["config", "--repo", str(self.base)]), 0)
        self.assertEqual(json.loads(buffer.getvalue()), {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "follow"})

    def test_cli_config_set_writes_warn_round_trips(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.assertEqual(main(["config", "--repo", str(self.base), "set", "writes", "warn"]), 0)
        self.assertEqual(json.loads(buffer.getvalue())["writes"], "warn")
        self.assertEqual(read_config(self.base)["writes"], "warn")

    def test_cli_config_set_enabled_false(self) -> None:
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(["config", "--repo", str(self.base), "set", "enabled", "false"]), 0)
        self.assertFalse(read_config(self.base)["enabled"])

    def test_cli_config_init_writes_default_file(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.assertEqual(main(["config", "--repo", str(self.base), "init"]), 0)
        self.assertTrue(config_path(self.base).is_file())
        self.assertEqual(read_config(self.base), {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "follow"})
        # init refuses when the file already exists
        self.assertEqual(main(["config", "--repo", str(self.base), "init"]), 1)

    def test_cli_config_init_refuses_to_clobber(self) -> None:
        write_config(self.base, {"enabled": False, "writes": "off", "allowBypass": False})
        self.assertEqual(main(["config", "--repo", str(self.base), "init"]), 1)
        self.assertFalse(read_config(self.base)["enabled"])


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


def native(tool_name: str, **tool_input: str) -> dict[str, object]:
    return {"tool_name": tool_name, "command": "", "tool_input": tool_input}


if __name__ == "__main__":
    unittest.main()
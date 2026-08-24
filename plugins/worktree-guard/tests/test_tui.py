"""Headless tests for the interactive .wtg.json config UI."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.storage import config_path, read_config  # noqa: E402
from worktreeguard.tui import _config_loop  # noqa: E402


DEFAULTS = {"enabled": True, "writes": "block", "allowBypass": True, "branchChanges": "follow"}


class ConfigLoopTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-tui-")
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

    def loop(self, keys):
        key_iter = iter(keys)
        return _config_loop(
            self.base, config_path(self.base), read_config(self.base),
            lambda: next(key_iter), lambda _: None,
        )

    def test_save_writes_toggled_and_warned_config(self) -> None:
        # items: 0 enabled, 1 writes, 2 branchChanges, 3 allowBypass, 4 save, 5 cancel
        keys = [
            "enter",                 # toggle enabled (true -> false)
            "down", "enter",         # focus writes, open picker
            "down", "down", "enter", # picker: block -> off -> warn, confirm
            "down", "down", "down", "enter",  # writes -> branchChanges -> allowBypass -> save
        ]
        output: list[str] = []
        key_iter = iter(keys)
        self.assertEqual(
            _config_loop(self.base, config_path(self.base), read_config(self.base),
                          lambda: next(key_iter), output.append), 0
        )
        saved = read_config(self.base)
        self.assertEqual(saved, {"enabled": False, "writes": "warn", "allowBypass": True, "branchChanges": "follow"})
        self.assertTrue(any("writes" in frame for frame in output))
        self.assertTrue(any("Saved" in frame for frame in output))

    def test_branch_changes_picker_sets_manual(self) -> None:
        keys = [
            "down", "down", "enter",   # writes -> branchChanges, open picker
            "down", "enter",           # picker: follow -> manual, confirm
            "down", "down", "enter",   # branchChanges -> allowBypass -> save
        ]
        key_iter = iter(keys)
        output: list[str] = []
        self.assertEqual(
            _config_loop(self.base, config_path(self.base), read_config(self.base),
                          lambda: next(key_iter), output.append), 0
        )
        self.assertEqual(read_config(self.base)["branchChanges"], "manual")
        self.assertTrue(any("branchChanges" in frame for frame in output))

    def test_cancel_with_changes_does_not_write(self) -> None:
        self.assertEqual(self.loop(["enter", "esc"]), 0)
        self.assertFalse(config_path(self.base).exists())

    def test_cancel_without_changes_is_clean(self) -> None:
        output: list[str] = []
        key_iter = iter(["q"])
        self.assertEqual(
            _config_loop(self.base, config_path(self.base), read_config(self.base),
                          lambda: next(key_iter), output.append), 0
        )
        self.assertFalse(config_path(self.base).exists())
        self.assertTrue(any("No changes" in frame for frame in output))

    def test_writes_picker_back_returns_without_change(self) -> None:
        keys = ["down", "enter", "esc", "down", "down", "down", "enter"]
        self.assertEqual(self.loop(keys), 0)
        self.assertEqual(read_config(self.base), DEFAULTS)

    def test_s_key_saves(self) -> None:
        self.assertEqual(self.loop(["s"]), 0)
        self.assertTrue(config_path(self.base).is_file())

    def test_existing_config_is_loaded_as_starting_state(self) -> None:
        config_path(self.base).write_text(
            json.dumps({"enabled": False, "writes": "off", "allowBypass": False}), encoding="utf-8",
        )
        key_iter = iter(["s"])
        self.assertEqual(
            _config_loop(self.base, config_path(self.base), read_config(self.base),
                          lambda: next(key_iter), lambda _: None), 0
        )
        self.assertEqual(read_config(self.base),
                         {"enabled": False, "writes": "off", "allowBypass": False, "branchChanges": "follow"})


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
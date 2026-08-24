"""Headless tests for the interactive .wtg.json config UI."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.storage import config_path, default_config, read_config  # noqa: E402
from worktreeguard.tui import _config_loop  # noqa: E402


DEFAULTS = default_config()

# items: 0 enabled, 1 writes, 2 branchChanges, 3 discard, 4 stash, 5 save, 6 cancel
ENABLED, WRITES, BRANCH_CHANGES, DISCARD, STASH, SAVE, CANCEL = range(7)


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

    def run_loop(self, keys):
        output: list[str] = []
        key_iter = iter(keys)
        code = _config_loop(
            self.base, config_path(self.base), read_config(self.base),
            lambda: next(key_iter), output.append,
        )
        return code, output

    def test_toggle_enabled_and_save(self) -> None:
        keys = ["enter"] + ["down"] * (SAVE - ENABLED) + ["enter"]
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        self.assertFalse(read_config(self.base)["enabled"])
        self.assertTrue(any("Saved" in frame for frame in output))

    def test_writes_disposition_warn_no_bypass_step_since_not_block(self) -> None:
        # Picker cursors start on the *current* value, and the default disposition
        # is "block" (index 2 of allow/warn/block) — one "up" reaches "warn".
        keys = (
            ["down"] * (WRITES - ENABLED) + ["enter"]  # focus writes, open picker (starts at block)
            + ["up", "enter"]  # block -> warn, confirm (no bypass step follows: not block)
            + ["down"] * (SAVE - WRITES) + ["enter"]  # navigate to save
        )
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        saved = read_config(self.base)
        self.assertEqual(saved["writes"]["disposition"], "warn")
        self.assertEqual(saved["writes"]["bypass"], "auto")  # untouched, still the default
        self.assertTrue(any("writes" in frame for frame in output))

    def test_writes_disposition_block_then_bypass_manual(self) -> None:
        keys = (
            ["down"] * (WRITES - ENABLED) + ["enter"]
            + ["enter"]  # disposition picker: block already selected, confirm as-is
            + ["down", "enter"]  # bypass picker opens automatically: auto -> manual, confirm
            + ["down"] * (SAVE - WRITES) + ["enter"]
        )
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        saved = read_config(self.base)
        self.assertEqual(saved["writes"], {"disposition": "block", "bypass": "manual"})

    def test_branch_changes_bypass_manual(self) -> None:
        keys = (
            ["down"] * (BRANCH_CHANGES - ENABLED) + ["enter"]  # focus branchChanges
            + ["enter"]  # disposition picker: block already selected, confirm as-is
            + ["down", "enter"]  # bypass picker: auto -> manual, confirm
            + ["down"] * (SAVE - BRANCH_CHANGES) + ["enter"]
        )
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        self.assertEqual(read_config(self.base)["branchChanges"]["bypass"], "manual")
        self.assertTrue(any("branchChanges" in frame for frame in output))

    def test_discard_and_stash_are_independently_editable(self) -> None:
        keys = (
            ["down"] * (DISCARD - ENABLED) + ["enter"]
            + ["enter"]  # disposition picker: block already selected, confirm as-is
            + ["down", "down", "enter"]  # bypass: auto -> manual -> none
            + ["down"] * (STASH - DISCARD) + ["enter"]
            + ["up", "enter"]  # stash disposition picker (starts at block): block -> warn
            + ["down"] * (SAVE - STASH) + ["enter"]
        )
        code, _ = self.run_loop(keys)
        self.assertEqual(code, 0)
        saved = read_config(self.base)
        self.assertEqual(saved["discard"], {"disposition": "block", "bypass": "none"})
        self.assertEqual(saved["stash"]["disposition"], "warn")

    def test_cancel_with_changes_does_not_write(self) -> None:
        self.assertEqual(self.loop(["enter", "esc"]), 0)
        self.assertFalse(config_path(self.base).exists())

    def test_cancel_without_changes_is_clean(self) -> None:
        code, output = self.run_loop(["q"])
        self.assertEqual(code, 0)
        self.assertFalse(config_path(self.base).exists())
        self.assertTrue(any("No changes" in frame for frame in output))

    def test_disposition_picker_back_returns_without_change(self) -> None:
        keys = (
            ["down"] * (WRITES - ENABLED) + ["enter"]  # focus writes, open picker
            + ["esc"]  # back out immediately
            + ["down"] * (SAVE - WRITES) + ["enter"]
        )
        self.assertEqual(self.loop(keys), 0)
        self.assertEqual(read_config(self.base), DEFAULTS)

    def test_bypass_picker_back_does_not_change_bypass(self) -> None:
        keys = (
            ["down"] * (WRITES - ENABLED) + ["enter"]
            + ["enter"]  # disposition picker: block already selected, confirm as-is
            + ["esc"]  # back out of the bypass picker without choosing
            + ["down"] * (SAVE - WRITES) + ["enter"]
        )
        self.assertEqual(self.loop(keys), 0)
        saved = read_config(self.base)
        self.assertEqual(saved["writes"], {"disposition": "block", "bypass": "auto"})

    def test_s_key_saves(self) -> None:
        self.assertEqual(self.loop(["s"]), 0)
        self.assertTrue(config_path(self.base).is_file())

    def test_existing_config_is_loaded_as_starting_state(self) -> None:
        config_path(self.base).write_text(
            json.dumps({"enabled": False, "writes": {"disposition": "allow"}}), encoding="utf-8",
        )
        self.assertEqual(self.loop(["s"]), 0)
        saved = read_config(self.base)
        self.assertFalse(saved["enabled"])
        self.assertEqual(saved["writes"]["disposition"], "allow")


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()

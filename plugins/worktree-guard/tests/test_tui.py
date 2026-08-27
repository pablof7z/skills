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
        # Toggling enabled off hides group rows; save lands at index 1.
        keys = ["enter", "down", "enter"]
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        self.assertFalse(read_config(self.base)["enabled"])
        self.assertTrue(any("Saved" in frame for frame in output))

    def test_writes_disposition_warn_no_bypass_step_since_not_block(self) -> None:
        # focus writes (sel=0, mode=block); enter cycles block -> warn.
        # No approval selector visible after change since mode != block.
        keys = (
            ["down"] * (WRITES - ENABLED)        # focus writes
            + ["enter"]                           # cycle disposition: block -> warn
            + ["down"] * (SAVE - WRITES) + ["enter"]
        )
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        saved = read_config(self.base)
        self.assertEqual(saved["writes"]["disposition"], "warn")
        self.assertEqual(saved["writes"]["bypass"], "auto")  # untouched
        self.assertTrue(any("writes" in frame for frame in output))

    def test_writes_disposition_block_then_bypass_manual(self) -> None:
        # focus writes; tab moves to approval selector (mode=block); enter cycles auto -> manual.
        keys = (
            ["down"] * (WRITES - ENABLED)  # focus writes
            + ["tab"]                       # advance to approval selector
            + ["enter"]                     # cycle bypass: auto -> manual
            + ["down"] * (SAVE - WRITES) + ["enter"]
        )
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        saved = read_config(self.base)
        self.assertEqual(saved["writes"], {"disposition": "block", "bypass": "manual"})

    def test_branch_changes_shows_configured_auto_approval_when_blocked(self) -> None:
        keys = ["down"] * (BRANCH_CHANGES - ENABLED) + ["s"]
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        all_output = "".join(output)
        self.assertIn("changing branch", all_output)
        self.assertIn("auto-approve", all_output)
        self.assertNotIn("never allowed", all_output)
        self.assertEqual(read_config(self.base)["branchChanges"]["bypass"], "auto")

    def test_branch_changes_right_selects_and_cycles_approval(self) -> None:
        keys = (
            ["down"] * (BRANCH_CHANGES - ENABLED)  # focus branchChanges
            + ["right", "enter"]                  # select approval; auto -> manual
            + ["down"] * (SAVE - BRANCH_CHANGES) + ["enter"]
        )
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        saved = read_config(self.base)
        self.assertEqual(saved["branchChanges"], {"disposition": "block", "bypass": "manual"})
        last_group_frames = [f for f in output if "changing branch" in f]
        self.assertTrue(last_group_frames)
        self.assertIn("require human approval", last_group_frames[-1])

    def test_branch_changes_message_editor_saves_exact_text(self) -> None:
        message = "Stay on THIS branch."
        keys = (
            ["down"] * (BRANCH_CHANGES - ENABLED)
            + ["m", *message, "enter"]
            + ["down"] * (SAVE - BRANCH_CHANGES) + ["enter"]
        )
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        self.assertEqual(read_config(self.base)["branchChanges"]["message"], message)
        self.assertIn("custom message", "".join(output))

    def test_message_editor_ctrl_u_clears_an_existing_override(self) -> None:
        config_path(self.base).write_text(
            json.dumps({"writes": {"message": "Original text"}}), encoding="utf-8",
        )
        keys = ["down", "m", "ctrl-u", "enter"] + ["down"] * (SAVE - WRITES) + ["enter"]
        self.assertEqual(self.loop(keys), 0)
        self.assertNotIn("message", read_config(self.base)["writes"])

    def test_message_editor_ctrl_n_inserts_a_line_break(self) -> None:
        keys = ["down", "m", "A", "ctrl-n", "B", "enter"] + ["down"] * (SAVE - WRITES) + ["enter"]
        self.assertEqual(self.loop(keys), 0)
        self.assertEqual(read_config(self.base)["writes"]["message"], "A\nB")

    def test_discard_and_stash_are_independently_editable(self) -> None:
        keys = (
            ["down"] * (DISCARD - ENABLED)    # focus discard, sel=0
            + ["tab"]                          # advance to approval selector
            + ["enter", "enter"]               # bypass: auto -> manual -> none
            + ["down"]                         # focus stash, sel resets to 0
            + ["enter"]                        # disposition: block -> warn
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

    def test_navigation_without_edit_preserves_defaults(self) -> None:
        # Navigating to group rows without cycling leaves data unchanged.
        keys = ["down"] * (SAVE - ENABLED) + ["enter"]
        self.assertEqual(self.loop(keys), 0)
        self.assertEqual(read_config(self.base), DEFAULTS)

    def test_approval_selector_navigate_away_without_enter_preserves_bypass(self) -> None:
        # Navigate to approval selector via tab, then move away without pressing enter.
        keys = (
            ["down"]   # focus writes, sel=0
            + ["tab"]  # advance to approval selector (sel=1, mode=block)
            + ["down"] * (SAVE - WRITES) + ["enter"]  # navigate away; sel resets, no change
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


    def test_disabled_config_hides_group_rows(self) -> None:
        # When enabled=false on load, group rows are absent from the rendered output.
        config_path(self.base).write_text(
            json.dumps({"enabled": False}), encoding="utf-8"
        )
        keys = ["down", "enter"]  # focus save (index 1 when disabled), save
        code, output = self.run_loop(keys)
        self.assertEqual(code, 0)
        all_output = "".join(output)
        self.assertNotIn("file writes", all_output)
        self.assertNotIn("changing branch", all_output)


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()

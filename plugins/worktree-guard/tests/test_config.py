"""Tests for the per-repo ``.wtg.json`` configuration."""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.cli import main  # noqa: E402
from worktreeguard.core import GUARD_GROUPS  # noqa: E402
from worktreeguard.policy import (  # noqa: E402
    blocked_git_operation, blocked_operation, warned_git_operation, warned_operation,
)
from worktreeguard.storage import (  # noqa: E402
    DEFAULT_CONFIG, config_path, default_config, read_config, repo_config, set_config_value,
    write_config,
)


DEFAULT_JSON = {
    "enabled": True,
    "writes": {"disposition": "block", "bypass": "auto"},
    "branchChanges": {"disposition": "block", "bypass": "auto"},
    "discard": {"disposition": "block", "bypass": "auto"},
    "stash": {"disposition": "block", "bypass": "auto"},
}


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

    def test_missing_config_defaults_to_enabled_block_auto_everywhere(self) -> None:
        config = repo_config(self.base)
        self.assertEqual(config, DEFAULT_CONFIG)
        self.assertEqual(config_path(self.base), self.base / ".wtg.json")
        self.assertEqual(read_config(self.base), DEFAULT_JSON)
        self.assertEqual(default_config(), DEFAULT_JSON)

    def test_enabled_false_disables_every_group(self) -> None:
        write_config(self.base, {"enabled": False})
        self.assertFalse(repo_config(self.base).enabled)
        self.assertIsNone(blocked_git_operation("git reset --hard", self.base))
        self.assertIsNone(blocked_git_operation("git stash", self.base))
        self.assertIsNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))
        self.assertIsNone(warned_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_writes_allow_allows_writes_but_git_still_blocked(self) -> None:
        write_config(self.base, {"writes": {"disposition": "allow"}})
        self.assertIsNotNone(blocked_git_operation("git reset --hard", self.base))
        self.assertIsNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))
        self.assertIsNone(warned_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_writes_warn_warns_without_blocking(self) -> None:
        write_config(self.base, {"writes": {"disposition": "warn"}})
        self.assertIsNotNone(blocked_git_operation("git reset --hard", self.base))
        self.assertIsNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))
        self.assertIsNotNone(warned_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_writes_block_blocks_writes(self) -> None:
        write_config(self.base, {"writes": {"disposition": "block"}})
        self.assertIsNotNone(blocked_operation(native("Write", path=str(self.base / "new.txt")), self.base))
        self.assertIsNone(warned_operation(native("Write", path=str(self.base / "new.txt")), self.base))

    def test_every_group_independently_supports_every_disposition(self) -> None:
        # "all commands can have all states of blocking and bypassing" — no group is
        # special-cased to a subset of dispositions.
        commands = {
            "branchChanges": "git switch main",
            "discard": "git reset --hard",
            "stash": "git stash",
        }
        for group, command in commands.items():
            for disposition in ("allow", "warn", "block"):
                with self.subTest(group=group, disposition=disposition):
                    write_config(self.base, {group: {"disposition": disposition}})
                    blocked = blocked_git_operation(command, self.base)
                    warned = warned_git_operation(command, self.base)
                    if disposition == "block":
                        self.assertIsNotNone(blocked)
                        self.assertIsNone(warned)
                    elif disposition == "warn":
                        self.assertIsNone(blocked)
                        self.assertIsNotNone(warned)
                    else:
                        self.assertIsNone(blocked)
                        self.assertIsNone(warned)

    def test_linked_worktree_is_always_unrestricted(self) -> None:
        for disposition in ("block", "allow", "warn"):
            with self.subTest(disposition=disposition):
                write_config(self.base, {"writes": {"disposition": disposition}})
                self.assertIsNone(blocked_git_operation("git reset --hard", self.linked))
                self.assertIsNone(blocked_operation(native("Write", path=str(self.linked / "new.txt")), self.linked))
                self.assertIsNone(warned_operation(native("Write", path=str(self.linked / "new.txt")), self.linked))

    def test_partial_config_merges_with_defaults_per_field(self) -> None:
        config_path(self.base).write_text(
            json.dumps({"writes": {"disposition": "warn"}}), encoding="utf-8",
        )
        config = repo_config(self.base)
        self.assertTrue(config.enabled)
        self.assertEqual(config.writes.disposition, "warn")
        self.assertEqual(config.writes.bypass, "auto")
        self.assertEqual(config.branch_changes, DEFAULT_CONFIG.branch_changes)

    def test_invalid_disposition_value_falls_back_to_block(self) -> None:
        config_path(self.base).write_text(json.dumps({"writes": {"disposition": "bogus"}}), encoding="utf-8")
        self.assertEqual(repo_config(self.base).writes.disposition, "block")

    def test_invalid_bypass_value_falls_back_to_auto(self) -> None:
        config_path(self.base).write_text(json.dumps({"writes": {"bypass": "bogus"}}), encoding="utf-8")
        self.assertEqual(repo_config(self.base).writes.bypass, "auto")

    def test_malformed_config_falls_back_to_defaults(self) -> None:
        config_path(self.base).write_text("{not json", encoding="utf-8")
        self.assertEqual(repo_config(self.base), DEFAULT_CONFIG)

    def test_read_config_returns_serializable_mapping(self) -> None:
        write_config(self.base, {"writes": {"disposition": "warn", "bypass": "manual"}})
        config = read_config(self.base)
        self.assertEqual(config["writes"], {"disposition": "warn", "bypass": "manual"})
        self.assertEqual(config["stash"], {"disposition": "block", "bypass": "auto"})

    def test_set_config_value_rejects_unknown_key(self) -> None:
        from worktreeguard.core import WorktreeGuardError
        with self.assertRaises(WorktreeGuardError):
            set_config_value(self.base, "bogus", "1")
        with self.assertRaises(WorktreeGuardError):
            set_config_value(self.base, "writes.bogus", "1")
        with self.assertRaises(WorktreeGuardError):
            set_config_value(self.base, "bogusgroup.disposition", "block")

    def test_set_config_value_rejects_invalid_disposition(self) -> None:
        from worktreeguard.core import WorktreeGuardError
        with self.assertRaises(WorktreeGuardError):
            set_config_value(self.base, "writes.disposition", "bogus")

    def test_set_config_value_rejects_invalid_bypass(self) -> None:
        from worktreeguard.core import WorktreeGuardError
        with self.assertRaises(WorktreeGuardError):
            set_config_value(self.base, "writes.bypass", "bogus")

    def test_set_config_value_updates_one_group_leaves_others_untouched(self) -> None:
        set_config_value(self.base, "writes.bypass", "manual")
        config = read_config(self.base)
        self.assertEqual(config["writes"], {"disposition": "block", "bypass": "manual"})
        self.assertEqual(config["discard"], {"disposition": "block", "bypass": "auto"})

    def test_cli_config_show_prints_effective_defaults(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.assertEqual(main(["config", "--repo", str(self.base), "--json"]), 0)
        self.assertEqual(json.loads(buffer.getvalue()), DEFAULT_JSON)

    def test_cli_config_set_writes_disposition_round_trips(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.assertEqual(
                main(["config", "--repo", str(self.base), "set", "writes.disposition", "warn"]), 0,
            )
        self.assertEqual(json.loads(buffer.getvalue())["writes"]["disposition"], "warn")
        self.assertEqual(read_config(self.base)["writes"]["disposition"], "warn")

    def test_cli_config_set_enabled_false(self) -> None:
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(["config", "--repo", str(self.base), "set", "enabled", "false"]), 0)
        self.assertFalse(read_config(self.base)["enabled"])

    def test_cli_config_init_writes_default_file(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.assertEqual(main(["config", "--repo", str(self.base), "init"]), 0)
        self.assertTrue(config_path(self.base).is_file())
        self.assertEqual(read_config(self.base), DEFAULT_JSON)
        # init refuses when the file already exists
        self.assertEqual(main(["config", "--repo", str(self.base), "init"]), 1)

    def test_cli_config_init_refuses_to_clobber(self) -> None:
        write_config(self.base, {"enabled": False})
        self.assertEqual(main(["config", "--repo", str(self.base), "init"]), 1)
        self.assertFalse(read_config(self.base)["enabled"])

    def test_all_four_groups_are_configurable(self) -> None:
        self.assertEqual(set(GUARD_GROUPS), {"writes", "branchChanges", "discard", "stash"})


class LegacyMigrationTests(unittest.TestCase):
    """A pre-groups ``.wtg.json`` (writes/branchChanges/allowBypass, no discard/stash
    keys) must upgrade to the equivalent new-shape policy on read, so an existing
    repo's real prior behavior survives the migration untouched."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-legacy-")
        root = Path(self.temporary.name).resolve()
        self.base = root / "repo"
        run(["git", "init", "-q", "-b", "main", str(self.base)])

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_legacy(self, data: dict) -> None:
        config_path(self.base).write_text(json.dumps(data), encoding="utf-8")

    def test_legacy_writes_off_becomes_allow(self) -> None:
        self.write_legacy({"writes": "off"})
        self.assertEqual(repo_config(self.base).writes.disposition, "allow")

    def test_legacy_writes_warn_stays_warn(self) -> None:
        self.write_legacy({"writes": "warn"})
        self.assertEqual(repo_config(self.base).writes.disposition, "warn")

    def test_legacy_writes_block_stays_block(self) -> None:
        self.write_legacy({"writes": "block"})
        self.assertEqual(repo_config(self.base).writes.disposition, "block")

    def test_legacy_allow_bypass_true_becomes_auto_everywhere_absent(self) -> None:
        self.write_legacy({"writes": "block", "allowBypass": True})
        config = repo_config(self.base)
        self.assertEqual(config.writes.bypass, "auto")
        self.assertEqual(config.discard.bypass, "auto")
        self.assertEqual(config.stash.bypass, "auto")

    def test_legacy_allow_bypass_false_becomes_manual_everywhere_absent(self) -> None:
        self.write_legacy({"writes": "block", "allowBypass": False})
        config = repo_config(self.base)
        self.assertEqual(config.writes.bypass, "manual")
        self.assertEqual(config.discard.bypass, "manual")
        self.assertEqual(config.stash.bypass, "manual")

    def test_legacy_branch_changes_follow_defers_to_allow_bypass(self) -> None:
        self.write_legacy({"branchChanges": "follow", "allowBypass": False})
        config = repo_config(self.base)
        self.assertEqual(config.branch_changes.disposition, "block")
        self.assertEqual(config.branch_changes.bypass, "manual")

    def test_legacy_branch_changes_manual_ignores_allow_bypass_true(self) -> None:
        self.write_legacy({"branchChanges": "manual", "allowBypass": True})
        config = repo_config(self.base)
        self.assertEqual(config.branch_changes.disposition, "block")
        self.assertEqual(config.branch_changes.bypass, "manual")

    def test_legacy_branch_changes_block_becomes_bypass_none(self) -> None:
        self.write_legacy({"branchChanges": "block"})
        config = repo_config(self.base)
        self.assertEqual(config.branch_changes.disposition, "block")
        self.assertEqual(config.branch_changes.bypass, "none")

    def test_legacy_file_with_no_stash_key_still_guards_stash(self) -> None:
        # The gap this redesign closes: stash was never blockable before, but an old
        # config upgrades to the same strictness as every other group, not "allow".
        self.write_legacy({"writes": "block", "allowBypass": True})
        config = repo_config(self.base)
        self.assertEqual(config.stash.disposition, "block")
        self.assertEqual(config.stash.bypass, "auto")


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


def native(tool_name: str, **tool_input: str) -> dict[str, object]:
    return {"tool_name": tool_name, "command": "", "tool_input": tool_input}


if __name__ == "__main__":
    unittest.main()

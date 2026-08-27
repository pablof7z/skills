"""Tests for concise WorktreeGuard denial guidance and approval hints."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.audit import approval_hint, denial_message, warn_message  # noqa: E402
from worktreeguard.policy import BlockedFileOperation, BlockedGitOperation  # noqa: E402
from worktreeguard.storage import DEFAULT_CONFIG, GroupPolicy, RepoConfig  # noqa: E402


def config_with(**groups: GroupPolicy) -> RepoConfig:
    fields = {
        "enabled": True,
        "writes": DEFAULT_CONFIG.writes,
        "branch_changes": DEFAULT_CONFIG.branch_changes,
        "discard": DEFAULT_CONFIG.discard,
        "stash": DEFAULT_CONFIG.stash,
    }
    fields.update(groups)
    return RepoConfig(**fields)


class DenialMessageTests(unittest.TestCase):
    def test_denial_includes_worktree_nudge_and_auto_approval_hint(self) -> None:
        base = Path("/repo")
        command = "git reset --hard\n\ngit status"
        message = denial_message(
            BlockedGitOperation("reset", command, base, base, False, "discard"), DEFAULT_CONFIG,
        )
        self.assertIn("Shouldn't you be working on a Git worktree?", message)
        self.assertIn(f"Rejected command:\n{command}", message)
        self.assertIn("A request will be automatically approved.", message)
        self.assertIn("wtg request-base-access --scope discard --repo /repo --reason", message)
        self.assertNotIn("/plugins/worktree-guard", message)

    def test_denial_for_a_file_write_names_the_writes_group(self) -> None:
        base = Path("/repo")
        message = denial_message(
            BlockedFileOperation("Edit", base, base, base / "f.txt"), DEFAULT_CONFIG,
        )
        self.assertIn("the native `Edit` tool in the base checkout", message)
        self.assertIn("--scope writes", message)


class ApprovalHintTests(unittest.TestCase):
    base = Path("/repo")

    def test_bypass_auto_auto_approves(self) -> None:
        hint = approval_hint(config_with(writes=GroupPolicy("block", "auto")), self.base, "writes")
        self.assertIn("automatically approved", hint)
        self.assertIn("--scope writes", hint)

    def test_bypass_manual_requires_manual(self) -> None:
        hint = approval_hint(config_with(writes=GroupPolicy("block", "manual")), self.base, "writes")
        self.assertIn("wait up to 300 seconds", hint)
        self.assertIn("auto-approval is disabled for this scope", hint)
        self.assertIn("--scope writes", hint)

    def test_bypass_none_says_auto_denied_and_no_request_command(self) -> None:
        hint = approval_hint(config_with(discard=GroupPolicy("block", "none")), self.base, "discard")
        self.assertIn("automatically denied", hint)
        self.assertIn("won't help", hint)
        self.assertNotIn("request-base-access", hint)

    def test_every_policy_gets_its_own_hint_naming_the_request_scope(self) -> None:
        for group, scope in (
            ("writes", "writes"),
            ("branchChanges", "change-branch"),
            ("discard", "discard"),
            ("stash", "stash"),
        ):
            with self.subTest(scope=scope):
                hint = approval_hint(DEFAULT_CONFIG, self.base, group)
                self.assertIn(f"--scope {scope}", hint)


class WarnMessageTests(unittest.TestCase):
    def test_warn_message_for_a_file_write_names_the_base_and_target(self) -> None:
        base = Path("/repo")
        target = base / "tracked.txt"
        message = warn_message(BlockedFileOperation("Edit", base, base, target))
        self.assertIn("You are modifying the base directory of a protected repo", message)
        self.assertIn("shouldn't be working on a git worktree?", message)
        self.assertIn(str(base), message)
        self.assertIn(str(target), message)

    def test_warn_message_for_a_git_command_names_the_subcommand(self) -> None:
        base = Path("/repo")
        message = warn_message(BlockedGitOperation("stash", "git stash", base, base, False, "stash"))
        self.assertIn("git stash", message)
        self.assertIn("shouldn't be working on a git worktree?", message)
        self.assertIn(str(base), message)


if __name__ == "__main__":
    unittest.main()

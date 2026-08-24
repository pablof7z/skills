"""Tests for concise WorktreeGuard denial guidance and approval hints."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.audit import approval_hint, denial_message, warn_message  # noqa: E402
from worktreeguard.policy import BlockedFileOperation, BlockedGitOperation  # noqa: E402
from worktreeguard.storage import DEFAULT_CONFIG, RepoConfig  # noqa: E402


class DenialMessageTests(unittest.TestCase):
    def test_denial_includes_worktree_nudge_and_auto_approval_hint(self) -> None:
        base = Path("/repo")
        command = "git reset --hard\n\ngit status"
        message = denial_message(
            BlockedGitOperation("reset", command, base, base, False), DEFAULT_CONFIG,
        )
        self.assertIn("Shouldn't you be working on a Git worktree?", message)
        self.assertIn(f"Rejected command:\n{command}", message)
        self.assertIn("A request will be automatically approved.", message)
        self.assertIn("wtg request-base-access --repo /repo --reason", message)
        self.assertNotIn("/plugins/worktree-guard", message)


class ApprovalHintTests(unittest.TestCase):
    base = Path("/repo")

    def test_allow_bypass_true_auto_approves(self) -> None:
        hint = approval_hint(DEFAULT_CONFIG, self.base, is_branch_change=False)
        self.assertIn("automatically approved", hint)
        self.assertNotIn("--branch-change", hint)

    def test_allow_bypass_false_requires_manual(self) -> None:
        config = RepoConfig(True, "block", False, "follow")
        hint = approval_hint(config, self.base, is_branch_change=False)
        self.assertIn("block until the user manually responds", hint)
        self.assertNotIn("--branch-change", hint)

    def test_branch_manual_says_manual_and_uses_branch_change_flag(self) -> None:
        config = RepoConfig(True, "block", True, "manual")
        hint = approval_hint(config, self.base, is_branch_change=True)
        self.assertIn("block until the user manually responds", hint)
        self.assertIn("auto-approval is disabled for branch changes", hint)
        self.assertIn("--branch-change", hint)

    def test_branch_block_says_auto_denied_and_no_request(self) -> None:
        config = RepoConfig(True, "block", True, "block")
        hint = approval_hint(config, self.base, is_branch_change=True)
        self.assertIn("automatically denied", hint)
        self.assertIn("won't help", hint)
        self.assertNotIn("request-base-access", hint)

    def test_branch_follow_with_bypass_auto_approves(self) -> None:
        config = RepoConfig(True, "block", True, "follow")
        hint = approval_hint(config, self.base, is_branch_change=True)
        self.assertIn("automatically approved", hint)
        self.assertNotIn("--branch-change", hint)


class WarnMessageTests(unittest.TestCase):
    def test_warn_message_names_the_base_and_target(self) -> None:
        base = Path("/repo")
        target = base / "tracked.txt"
        message = warn_message(BlockedFileOperation("Edit", base, base, target))
        self.assertIn("You are modifying the base directory of a protected repo", message)
        self.assertIn("shouldn't be working on a git worktree?", message)
        self.assertIn(str(base), message)
        self.assertIn(str(target), message)


if __name__ == "__main__":
    unittest.main()
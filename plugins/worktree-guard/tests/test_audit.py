"""Tests for concise WorktreeGuard denial guidance."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.audit import denial_message  # noqa: E402
from worktreeguard.policy import BlockedGitOperation  # noqa: E402


class DenialMessageTests(unittest.TestCase):
    def test_denial_points_to_worktree_and_short_permission_command(self) -> None:
        base = Path("/repo")
        command = "git reset --hard\n\ngit status"
        message = denial_message(BlockedGitOperation("reset", command, base, base))

        self.assertIn("Shouldn't you be working on a Git worktree?", message)
        self.assertIn(f"Rejected command:\n{command}", message)
        self.assertIn(
            "If you really meant to work in the base checkout, use "
            "`wtg request-base-access --repo /repo --reason \"<why>\"` "
            "to request permission.",
            message,
        )
        self.assertNotIn("Non-Git shell commands", message)
        self.assertNotIn("/plugins/worktree-guard", message)


if __name__ == "__main__":
    unittest.main()

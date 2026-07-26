"""Tests for ChiefOfStaffGuard's fail-closed denial guidance."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from chiefofstaffguard.audit import denial_message  # noqa: E402
from chiefofstaffguard.policy import BlockedFileOperation, BlockedShellOperation  # noqa: E402


class DenialMessageTests(unittest.TestCase):
    def test_shell_denial_names_the_command_and_reason(self) -> None:
        operation = BlockedShellOperation(
            command="gh pr merge 42 --squash",
            cwd=Path("/repo"),
            program="gh",
            reason="`gh pr merge` is not on the allowlist",
        )
        message = denial_message(operation)

        self.assertIn("ChiefOfStaffGuard blocked `gh pr merge 42 --squash`.", message)
        self.assertIn("Reason: `gh pr merge` is not on the allowlist", message)
        self.assertIn("chief-of-staff orchestrates and dispatches", message)
        self.assertIn("mosaico dispatch <agent>@<backend>", message)
        self.assertIn("There is no agent-driven override for this guard.", message)

    def test_file_denial_names_the_tool_and_target(self) -> None:
        operation = BlockedFileOperation(
            tool_name="Edit", cwd=Path("/repo"), target=Path("/repo/main.py"),
        )
        message = denial_message(operation)

        self.assertIn("the native `Edit` tool (target: /repo/main.py)", message)
        self.assertIn(
            "Reason: chief-of-staff may only write inside its own tracking-repo home",
            message,
        )

    def test_denial_message_has_no_self_serve_override(self) -> None:
        operation = BlockedShellOperation(command="kill -9 1", cwd=Path("/repo"), program="kill", reason="process control")
        message = denial_message(operation)
        self.assertNotIn("request-base-access", message)
        self.assertNotIn("--override", message)


if __name__ == "__main__":
    unittest.main()

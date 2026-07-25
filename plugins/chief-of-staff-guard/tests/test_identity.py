"""Tests for chief-of-staff session identity detection.

`MOSAICO_AGENT` is the signal mosaico's own `mosaico harness hook
claude-code ...` dispatcher uses to resolve "which agent is this session"
(mosaico `src/cli.rs` `agent_env_slug()`, fed by `src/pty/supervisor.rs`
setting `MOSAICO_AGENT` on every process it spawns for a dispatched agent).
These tests pin the exact precedence ChiefOfStaffGuard reuses from that
resolution order.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from chiefofstaffguard.identity import is_chief_of_staff_session  # noqa: E402


class IdentityTests(unittest.TestCase):
    def test_mosaico_agent_chief_of_staff_is_guarded(self) -> None:
        self.assertTrue(is_chief_of_staff_session({"MOSAICO_AGENT": "chief-of-staff"}))

    def test_mosaico_agent_other_slug_is_not_guarded(self) -> None:
        self.assertFalse(is_chief_of_staff_session({"MOSAICO_AGENT": "orbit-builder"}))

    def test_mosaico_agent_wins_over_stale_claude_code_agent(self) -> None:
        # A plain subprocess spawned from a chief-of-staff shell (e.g. a
        # backgrounded `claude -p ...` that did not go through `mosaico
        # dispatch`) can inherit CLAUDE_CODE_AGENT=chief-of-staff without
        # mosaico itself having dispatched it as chief-of-staff.
        # MOSAICO_AGENT, when set, is authoritative either way.
        env = {"MOSAICO_AGENT": "orbit-builder", "CLAUDE_CODE_AGENT": "chief-of-staff"}
        self.assertFalse(is_chief_of_staff_session(env))

    def test_falls_back_to_claude_code_agent_when_mosaico_agent_absent(self) -> None:
        self.assertTrue(is_chief_of_staff_session({"CLAUDE_CODE_AGENT": "chief-of-staff"}))

    def test_blank_mosaico_agent_falls_back_to_claude_code_agent(self) -> None:
        env = {"MOSAICO_AGENT": "", "CLAUDE_CODE_AGENT": "chief-of-staff"}
        self.assertTrue(is_chief_of_staff_session(env))

    def test_no_signals_is_not_guarded(self) -> None:
        self.assertFalse(is_chief_of_staff_session({}))

    def test_codex_hosted_variant_slug_is_guarded(self) -> None:
        # Observed live in the fabric: chief-of-staff-codex is the
        # Codex-hosted instance of the same chief-of-staff persona.
        self.assertTrue(is_chief_of_staff_session({"MOSAICO_AGENT": "chief-of-staff-codex"}))

    def test_similarly_named_but_distinct_slug_is_not_guarded(self) -> None:
        self.assertFalse(is_chief_of_staff_session({"MOSAICO_AGENT": "chief-of-staffing"}))


if __name__ == "__main__":
    unittest.main()

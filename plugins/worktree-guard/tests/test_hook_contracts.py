"""Tests that probes reject cross-harness hook response mixtures."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from hook_contracts import denial_decision  # noqa: E402


class HookContractTests(unittest.TestCase):
    def test_codex_denial_matches_codex_contract(self) -> None:
        body = {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "blocked",
        }}
        self.assertEqual(denial_decision("codex", body), ("deny", ""))

    def test_codex_rejects_old_mixed_grok_decision(self) -> None:
        body = {
            "decision": "deny",
            "reason": "blocked",
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "blocked",
            },
        }
        decision, error = denial_decision("codex", body)
        self.assertEqual(decision, "error")
        self.assertIn("decision", error)

    def test_grok_denial_matches_grok_contract(self) -> None:
        self.assertEqual(
            denial_decision("grok", {"decision": "deny", "reason": "blocked"}),
            ("deny", ""),
        )


if __name__ == "__main__":
    unittest.main()

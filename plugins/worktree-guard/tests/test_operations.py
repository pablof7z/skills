"""Tests for operation details recovered from live harness payloads."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard.operations import recover_codex_exec_workdir  # noqa: E402


class CodexExecRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-operations-")
        self.transcript = Path(self.temporary.name) / "rollout.jsonl"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_recovers_workdir_from_direct_exec_command_call(self) -> None:
        self.write_transcript(
            {
                "type": "function_call",
                "name": "exec_command",
                "arguments": json.dumps({
                    "cmd": "git rebase origin/master",
                    "workdir": "/private/tmp/mosaico-linked",
                    "yield_time_ms": 1000,
                }),
                "internal_chat_message_metadata_passthrough": {"turn_id": "turn-1"},
            }
        )

        recovered = recover_codex_exec_workdir(self.payload("turn-1"))

        self.assertEqual(
            recovered["tool_input"]["workdir"], "/private/tmp/mosaico-linked"
        )

    def test_keeps_support_for_composed_exec_calls(self) -> None:
        source = (
            'const r = await tools.exec_command({"cmd":"git rebase origin/master",'
            '"workdir":"/private/tmp/mosaico-linked"}); text(r.output);'
        )
        self.write_transcript(
            {
                "type": "custom_tool_call",
                "name": "exec",
                "input": source,
                "internal_chat_message_metadata_passthrough": {"turn_id": "turn-1"},
            }
        )

        recovered = recover_codex_exec_workdir(self.payload("turn-1"))

        self.assertEqual(
            recovered["tool_input"]["workdir"], "/private/tmp/mosaico-linked"
        )

    def test_does_not_recover_workdir_from_another_turn(self) -> None:
        self.write_transcript(
            {
                "type": "function_call",
                "name": "exec_command",
                "arguments": json.dumps({
                    "cmd": "git rebase origin/master",
                    "workdir": "/private/tmp/mosaico-linked",
                }),
                "internal_chat_message_metadata_passthrough": {"turn_id": "turn-2"},
            }
        )

        recovered = recover_codex_exec_workdir(self.payload("turn-1"))

        self.assertNotIn("workdir", recovered["tool_input"])

    def payload(self, turn_id: str) -> dict[str, object]:
        return {
            "cwd": "/Users/pablofernandez/Work/mosaico",
            "transcript_path": str(self.transcript),
            "turn_id": turn_id,
            "tool_name": "Bash",
            "tool_input": {"command": "git rebase origin/master"},
        }

    def write_transcript(self, item: dict[str, object]) -> None:
        self.transcript.write_text(
            json.dumps({"type": "response_item", "payload": item}) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()

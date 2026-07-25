"""Tests that the harness shims route to the shared ChiefOfStaffGuard command."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ShimRoutingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cosg-shim-")
        self.fake = Path(self.temporary.name) / "fake-cosg"
        self.fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n', encoding="utf-8")
        self.fake.chmod(0o755)
        self.env = {**os.environ, "COSG_BIN": str(self.fake)}

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_codex_shim_routes_to_shared_command(self) -> None:
        self.assertEqual(self.run_shim("cosg-hook-codex", {}), "hook codex pre-tool-use")

    def test_claude_shim_routes_claude_transcript_to_claude_harness(self) -> None:
        payload = {"transcript_path": "/tmp/.claude/session.jsonl"}
        self.assertEqual(self.run_shim("cosg-hook-claude", payload), "hook claude pre-tool-use")

    def test_claude_shim_routes_codex_transcript_to_codex_harness(self) -> None:
        payload = {"transcript_path": "/tmp/.codex/session.jsonl"}
        self.assertEqual(self.run_shim("cosg-hook-claude", payload), "hook codex pre-tool-use")

    def run_shim(self, shim: str, payload: dict[str, object]) -> str:
        result = subprocess.run(
            [str(ROOT / "bin" / shim), "pre-tool-use"], input=json.dumps(payload),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Workspace attribution contracts for durable TTS queue items."""

from __future__ import annotations

from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from tts.tests.tts_test_support import KokoroHandler


ROOT = Path(__file__).resolve().parents[2]
TTS = ROOT / "tts" / "scripts" / "tts"


class WorkspaceAttributionTests(unittest.TestCase):
    def test_root_fallback_is_absent_but_explicit_workspace_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-workspace-attribution-") as temp:
            root = Path(temp)
            server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                environment = os.environ.copy()
                environment.update(
                    {
                        "KOKORO_API_ENDPOINT": (
                            f"http://127.0.0.1:{server.server_port}/v1/audio/speech"
                        ),
                        "TTS_SESSIONS_ROOT": str(root / "sessions"),
                        "TTS_STATE_DIR": str(root / "state"),
                    }
                )
                fallback = self.generate(environment)
                self.assertIsNone(self.item(root, fallback["id"])["workspace"])

                environment["TTS_WORKSPACE"] = "/private/repository"
                explicit = self.generate(environment)
                self.assertEqual(
                    self.item(root, explicit["id"])["workspace"],
                    "/private/repository",
                )
            finally:
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()

    def generate(self, environment: dict[str, str]) -> dict[str, object]:
        result = subprocess.run(
            [
                str(TTS),
                "--agent-name",
                "workspace-test",
                "--subject",
                "Workspace Attribution",
                "--summary",
                "Queue metadata distinguishes real workspaces from daemon plumbing.",
                "--no-play",
                "--message",
                "Workspace attribution test.",
            ],
            cwd="/",
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return json.loads(result.stdout)

    @staticmethod
    def item(root: Path, item_id: object) -> dict[str, object]:
        return json.loads(
            (root / "state" / "items" / f"{item_id}.json").read_text()
        )


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Lifecycle and CLI-boundary contracts for the remote TTS daemon."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


class RemoteDaemonLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-lifecycle-")
        self.state = Path(self.temporary.name)
        (self.state / "home").mkdir(parents=True)
        self.tts = Path(__file__).resolve().parents[2] / "tts" / "scripts" / "tts"
        self.environment = {
            **os.environ,
            "HOME": str(self.state / "home"),
            "TTS_STATE_DIR": str(self.state),
            "TTS_REMOTE_TRANSPORT": "file",
            "TTS_REMOTE_TRANSPORT_FILE": str(self.state / "transport.jsonl"),
            "TTS_REMOTE_NO_MENU": "1",
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_tts(
        self,
        *arguments: str,
        env: dict[str, str] | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.tts), *arguments],
            env={**self.environment, **(env or {})},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_daemon_lifecycle_status_uses_real_child_liveness(self) -> None:
        self.assertFalse(json.loads(self.run_tts("daemon", "status").stdout)["running"])
        fake_menu = self.state / "fake-menu"
        menu_marker = self.state / "menu-started"
        fake_menu.write_text("#!/bin/sh\n" f"touch {str(menu_marker)!r}\n", encoding="utf-8")
        fake_menu.chmod(0o700)

        started = json.loads(self.run_tts(
            "daemon", "start",
            env={"TTS_REMOTE_NO_MENU": "0", "TTS_REMOTE_MENU_COMMAND": str(fake_menu)},
        ).stdout)
        self.assertEqual(started["status"], "started")
        self.assertEqual(started["menu_bar"], "started")
        self.assertTrue(menu_marker.is_file())
        for _ in range(20):
            status = json.loads(self.run_tts("daemon", "status").stdout)
            if status["running"]:
                break
            time.sleep(0.1)
        self.assertTrue(status["running"])
        self.assertEqual(os.getsid(status["state"]["pid"]), status["state"]["pid"])

        duplicate = json.loads(self.run_tts("daemon", "start").stdout)
        self.assertEqual(duplicate["status"], "already_running")
        self.assertEqual(duplicate["pid"], status["state"]["pid"])
        self.assertEqual(json.loads(self.run_tts("daemon", "stop").stdout)["status"], "stopped")
        self.assertFalse(json.loads(self.run_tts("daemon", "status").stdout)["running"])

    def test_cli_boundary_emits_structured_remote_transport_error(self) -> None:
        self.run_tts("pair", "offer", "--relay", "wss://relay.example.test")
        result = self.run_tts(
            "daemon", "run", "--once", "--max-events", "1",
            env={"TTS_REMOTE_TRANSPORT": "unsupported"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        error = json.loads(result.stderr)
        self.assertEqual(error["error"]["code"], "remote_transport_error")
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()

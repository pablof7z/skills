#!/usr/bin/env python3
"""Contracts for durable paired-listener startup."""

from __future__ import annotations

import json
import os
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_remote_commands import daemon_start


class RemoteDaemonLaunchTests(unittest.TestCase):
    def test_listener_uses_home_instead_of_the_callers_working_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-daemon-launch-") as temporary:
            root = Path(temporary)
            home = root / "durable-home"
            home.mkdir()
            environment = {
                "HOME": str(home),
                "TTS_REMOTE_NO_MENU": "1",
                "TTS_STATE_DIR": str(root / "state"),
            }
            process = Mock(pid=4321)

            with (
                patch.dict(os.environ, environment, clear=False),
                patch("tts_remote_commands.pid_alive", return_value=False),
                patch("tts_remote_commands.subprocess.Popen", return_value=process) as popen,
            ):
                output = daemon_start(SimpleNamespace(dry_run=False))

            self.assertEqual(output, 0)
            self.assertEqual(popen.call_args.kwargs["cwd"], home)
            state = json.loads((root / "state" / "remote" / "daemon.json").read_text())
            self.assertEqual(state["pid"], 4321)


if __name__ == "__main__":
    unittest.main()

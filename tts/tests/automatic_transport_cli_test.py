#!/usr/bin/env python3
"""Contracts for transparent local-or-paired TTS routing."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class AutomaticTransportCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-auto-transport-")
        self.root = Path(self.temporary.name)
        self.laptop_state = self.root / "laptop"
        self.server_state = self.root / "server"
        (self.laptop_state / "home").mkdir(parents=True)
        (self.server_state / "home").mkdir(parents=True)
        self.tts = Path(__file__).resolve().parents[1] / "scripts" / "tts"
        self.transport_file = self.root / "transport.jsonl"

    def tearDown(self) -> None:
        self.run_tts("daemon", "stop", state=self.laptop_state, check=False)
        self.temporary.cleanup()

    def environment(self, state: Path) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update({
            "HOME": str(state / "home"),
            "TTS_STATE_DIR": str(state),
            "TTS_REMOTE_TRANSPORT": "file",
            "TTS_REMOTE_TRANSPORT_FILE": str(self.transport_file),
            "TTS_REMOTE_NO_MENU": "1",
            "TTS_GROUP_CONFIRM_TIMEOUT_SECONDS": "3",
        })
        environment.pop("KOKORO_API_ENDPOINT", None)
        environment.pop("KOKORO_ENV_FILE", None)
        return environment

    def run_tts(
        self,
        *arguments: str,
        state: Path,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.tts), *arguments],
            env=self.environment(state),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def pair(self) -> None:
        offer = json.loads(self.run_tts("pair", "offer", state=self.laptop_state).stdout)
        self.run_tts("daemon", "start", state=self.laptop_state)
        self.run_tts(
            "pair", "connect", "--code", offer["pair_code"],
            state=self.server_state,
        )
        self.run_tts("daemon", "stop", state=self.laptop_state)

    def test_ordinary_speech_uses_approved_pair_when_local_endpoint_is_absent(self) -> None:
        self.pair()

        result = self.run_tts(
            "--agent-name", "automatic transport",
            "--subject", "Ordinary speech chooses paired playback",
            "--message", "The agent does not choose a transport.",
            state=self.server_state,
        )

        output = json.loads(result.stdout)
        self.assertEqual(output["status"], "sent")
        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        request = events[-1]
        self.assertEqual(request["kind"], 9)
        self.assertEqual(request["content"], "The agent does not choose a transport.")
        self.assertIn(["agent", "automatic transport"], request["tags"])
        self.assertIn(["subject", "Ordinary speech chooses paired playback"], request["tags"])

    def test_missing_endpoint_still_explains_setup_when_no_pair_exists(self) -> None:
        result = self.run_tts(
            "--agent-name", "automatic transport",
            "--subject", "No playback destination is available",
            "--message", "This cannot be delivered.",
            state=self.server_state,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no TTS playback destination is available", result.stderr)

    def test_laptop_daemon_recreates_lost_group_and_peer_permissions(self) -> None:
        self.pair()
        self.transport_file.write_text("", encoding="utf-8")

        self.run_tts("daemon", "run", "--once", state=self.laptop_state)

        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        self.assertEqual([event["kind"] for event in events], [9007, 9000, 9000])
        backend = json.loads((self.server_state / "remote" / "backend.json").read_text())
        self.assertIn(["p", backend["pubkey"]], events[1]["tags"])
        self.assertIn(["p", backend["pubkey"], "admin"], events[2]["tags"])


if __name__ == "__main__":
    unittest.main()

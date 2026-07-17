#!/usr/bin/env python3
"""Regression coverage for cursor recovery after a brief relay interruption."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_remote_polling import events_for_laptop


class RecordingTransport:
    def __init__(self, events: list[dict[str, object]]) -> None:
        self.events_to_return = events
        self.since_values: list[int | None] = []

    def events(self, **kwargs) -> list[dict[str, object]]:
        self.since_values.append(kwargs.get("since"))
        return self.events_to_return


class RemotePollingRecoveryTests(unittest.TestCase):
    def test_next_poll_replays_a_short_cursor_overlap(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-polling-recovery-") as temporary:
            state = Path(temporary)
            request = {
                "id": "remote-request",
                "created_at": 1_000,
                "kind": 9,
                "tags": [["p", "laptop"], ["h", "tts"]],
            }
            relay = RecordingTransport([request])
            environment = {"TTS_STATE_DIR": str(state)}
            with (
                patch.dict(os.environ, environment, clear=False),
                patch("tts_remote_polling.polling_coordinates", return_value=(set(), {"wss://relay": {"tts"}})),
                patch("tts_remote_polling.transport", return_value=relay),
            ):
                events_for_laptop("laptop")
                events_for_laptop("laptop")

            self.assertEqual(relay.since_values, [None, 940])
            cursor = json.loads((state / "remote" / "relay-cursors.json").read_text())
            self.assertEqual(cursor["wss://relay|requests"], 1_000)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Regression coverage for durable remote-event delivery."""

from __future__ import annotations

import json
import os
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_remote_daemon import process_events
from tts_remote_inbox import pending_events, stage_events
from tts_remote_polling import events_for_laptop


class RecordingTransport:
    def __init__(self, events: list[dict[str, object]]) -> None:
        self.events_to_return = events
        self.since_values: list[int | None] = []

    def events(self, **kwargs) -> list[dict[str, object]]:
        self.since_values.append(kwargs.get("since"))
        return self.events_to_return


class RemotePollingRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-polling-recovery-")
        self.state = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, {"TTS_STATE_DIR": str(self.state)}, clear=False)
        self.environment.start()

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def test_poll_stages_event_before_advancing_exact_cursor(self) -> None:
        request = self.request(created_at=1_000)
        relay = RecordingTransport([request])
        with (
            patch("tts_remote_polling.polling_coordinates", return_value=(set(), {"wss://relay": {"tts"}})),
            patch("tts_remote_polling.transport", return_value=relay),
        ):
            fetched = events_for_laptop("laptop")
            events_for_laptop("laptop")

        self.assertEqual(fetched, [request])
        self.assertEqual(relay.since_values, [None, 1_000])
        cursor = json.loads((self.state / "remote" / "relay-cursors.json").read_text())
        self.assertEqual(cursor["wss://relay|requests"], 1_000)

    def test_cursor_does_not_advance_when_durable_stage_fails(self) -> None:
        relay = RecordingTransport([self.request(created_at=1_000)])
        with (
            patch("tts_remote_polling.polling_coordinates", return_value=(set(), {"wss://relay": {"tts"}})),
            patch("tts_remote_polling.transport", return_value=relay),
            patch("tts_remote_polling.stage_events", side_effect=OSError("disk unavailable")),
        ):
            with self.assertRaisesRegex(OSError, "disk unavailable"):
                events_for_laptop("laptop")

        self.assertFalse((self.state / "remote" / "relay-cursors.json").exists())

    def test_transient_handler_failure_keeps_event_for_retry(self) -> None:
        request = self.request(created_at=2_000)
        stage_events([request])
        args = SimpleNamespace(max_events=10)
        backend = {"pubkey": "laptop"}
        with (
            patch("tts_remote_daemon.events_for_laptop", side_effect=lambda _: pending_events()),
            patch("tts_remote_daemon.handle_pairing_event", return_value=False),
            patch("tts_remote_daemon.handle_request_event", side_effect=RuntimeError("offline")),
        ):
            with self.assertRaisesRegex(RuntimeError, "offline"):
                process_events(args, backend)

        self.assertEqual(pending_events(), [request])
        self.assertFalse((self.state / "remote" / "daemon-seen.json").exists())

        with (
            patch("tts_remote_daemon.events_for_laptop", side_effect=lambda _: pending_events()),
            patch("tts_remote_daemon.handle_pairing_event", return_value=False),
            patch("tts_remote_daemon.handle_request_event", return_value=True),
        ):
            self.assertEqual(process_events(args, backend), 1)

        self.assertEqual(pending_events(), [])
        seen = json.loads((self.state / "remote" / "daemon-seen.json").read_text())
        self.assertEqual(seen, ["remote-request"])

    @staticmethod
    def request(*, created_at: int) -> dict[str, object]:
        return {
            "id": "remote-request",
            "created_at": created_at,
            "kind": 9,
            "tags": [["p", "laptop"], ["h", "tts"]],
        }


if __name__ == "__main__":
    unittest.main()

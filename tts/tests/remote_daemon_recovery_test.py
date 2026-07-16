#!/usr/bin/env python3
"""Regression coverage for transient paired-listener failures."""

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

from tts_remote_listener import daemon_run


class RemoteDaemonRecoveryTests(unittest.TestCase):
    def test_long_running_listener_retries_transient_network_failures(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-daemon-recovery-") as temporary:
            state = Path(temporary)
            environment = {
                "TTS_STATE_DIR": str(state),
                "TTS_LISTENER_RETRY_SECONDS": "0.01",
            }
            args = SimpleNamespace(wait_seconds=0.55, once=False, max_events=10)
            profile_attempts = 0
            poll_attempts = 0

            def attempt_profile_publish(*_args, **_kwargs) -> None:
                nonlocal profile_attempts
                profile_attempts += 1
                if profile_attempts == 1:
                    raise RuntimeError("temporary profile failure")

            def attempt_event_poll(*_args, **_kwargs) -> int:
                nonlocal poll_attempts
                poll_attempts += 1
                if poll_attempts == 1:
                    raise RuntimeError("temporary relay failure")
                return 1 if poll_attempts == 2 else 0

            with (
                patch.dict(os.environ, environment, clear=False),
                patch(
                    "tts_remote_listener.ensure_laptop_identity",
                    return_value={"pubkey": "laptop", "nsec": "secret"},
                ),
                patch(
                    "tts_remote_listener.publish_laptop_profiles",
                    side_effect=attempt_profile_publish,
                ) as publish_profiles_mock,
                patch("tts_remote_listener.refresh_peer_profiles"),
                patch("tts_remote_listener.reconcile_paired_channels"),
                patch(
                    "tts_remote_listener.process_events",
                    side_effect=attempt_event_poll,
                ) as process_events_mock,
            ):
                self.assertEqual(daemon_run(args), 0)

            self.assertGreaterEqual(publish_profiles_mock.call_count, 2)
            self.assertGreaterEqual(process_events_mock.call_count, 2)
            daemon_state = json.loads((state / "remote" / "daemon.json").read_text())
            self.assertFalse(daemon_state["running"])


if __name__ == "__main__":
    unittest.main()

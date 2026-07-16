#!/usr/bin/env python3
"""Regression contracts for paired question materialization."""

from __future__ import annotations

from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_remote_daemon import (
    environment_enabled,
    materialization_guidance,
    materialize_request,
    safe_materialization_detail,
)
from tts.tests.tts_test_support import KokoroHandler


class RemoteAskMaterializationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-ask-")
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        self.home = self.root / "home"
        self.home.mkdir()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.environment = {
            "HOME": str(self.home),
            "KOKORO_API_ENDPOINT": (
                f"http://127.0.0.1:{self.server.server_port}/v1/audio/speech"
            ),
            "TTS_MACOS_MENU": "0",
            "TTS_REMOTE_DAEMON_NO_PLAY": "1",
            "TTS_SESSIONS_ROOT": str(self.root / "sessions"),
            "TTS_STATE_DIR": str(self.state),
        }

    def tearDown(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()
        self.temporary.cleanup()

    def test_listener_no_play_mode_does_not_disable_questions(self) -> None:
        question = {
            "questions": [{
                "attachments": [],
                "short_title": "Favorite place",
                "suggestions": [],
                "title": "What's your favorite place in the world?",
                "type": "single_choice",
            }]
        }
        content = {
            "agent_name": "Codex",
            "ask": json.dumps(question),
            "attachments": [],
            "message": "What's your favorite place in the world?",
            "request_id": "paired-question-test",
            "subject": "A simple spoken greeting test",
            "wait": "0.01s",
        }

        with patch.dict(os.environ, self.environment, clear=False):
            output = materialize_request(content, {"id": "request-event"})

        self.assertEqual(output["status"], "pending")
        item = json.loads(
            (self.state / "items" / "paired-question-test.json").read_text()
        )
        self.assertEqual(item["kind"], "question")
        self.assertIn(item["status"], {"queued", "playing"})
        self.assertEqual(item["remote_request"]["event_id"], "request-event")

    def test_listener_switch_requires_an_explicit_true_value(self) -> None:
        for false_value in ("", "0", "false", "no", "off"):
            with self.subTest(value=false_value):
                with patch.dict(
                    os.environ,
                    {"TTS_REMOTE_DAEMON_NO_PLAY": false_value},
                    clear=False,
                ):
                    self.assertFalse(environment_enabled("TTS_REMOTE_DAEMON_NO_PLAY"))

    def test_failure_guidance_reports_the_tts_error_instead_of_guessing(self) -> None:
        detail = safe_materialization_detail(
            "trace noise\nError: --ask is not compatible with --no-play.\n"
        )

        self.assertEqual(
            materialization_guidance(detail),
            "Laptop TTS: Error: --ask is not compatible with --no-play.",
        )


if __name__ == "__main__":
    unittest.main()

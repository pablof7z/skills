#!/usr/bin/env python3
"""CLI contract tests for the primary TTS message limit."""

from __future__ import annotations

from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from tts.tests.tts_test_support import KokoroHandler


class MessageLimitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-message-limit-")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.sessions = self.root / "sessions"
        self.repository = Path(__file__).resolve().parents[2]
        self.tts_command = self.repository / "tts" / "scripts" / "tts"

        with KokoroHandler.received_inputs_lock:
            KokoroHandler.received_inputs = []
            KokoroHandler.received_voices = []

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

        self.environment = os.environ.copy()
        self.environment.update(
            {
                "HOME": str(self.home),
                "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{self.server.server_port}/v1/audio/speech",
                "TTS_MACOS_MENU": "0",
                "TTS_SESSIONS_ROOT": str(self.sessions),
                "TTS_STATE_DIR": str(self.root / "state"),
            }
        )

    def tearDown(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()
        self.temporary.cleanup()

    @staticmethod
    def words(count: int) -> str:
        return " ".join(f"word{index}" for index in range(count))

    def run_primary(
        self,
        message: str,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(self.tts_command),
                "--agent-name",
                "message-limit-test",
                "--subject",
                "Keeping primary spoken updates within safe limits",
                "--summary",
                "Primary TTS messages stay within the safe playback boundary.",
                "--no-play",
                "--message",
                message,
            ],
            env=environment or self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_accepts_exactly_330_primary_words_without_counting_subject(self) -> None:
        result = self.run_primary(self.words(330))

        self.assertEqual(result.returncode, 0, result.stderr)
        with KokoroHandler.received_inputs_lock:
            self.assertEqual(len(KokoroHandler.received_inputs), 1)
            self.assertTrue(KokoroHandler.received_inputs[0].endswith("word329."))

    def test_rejects_331_primary_words_before_synthesis_or_state_creation(self) -> None:
        result = self.run_primary(self.words(331))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contains 331 words", result.stderr)
        self.assertIn("enforced limit is 330 words", result.stderr)
        self.assertIn("under 300 words", result.stderr)
        self.assertIn("readable Markdown", result.stderr)
        self.assertIn("labeled attachments", result.stderr)
        self.assertIn("--attach", result.stderr)
        with KokoroHandler.received_inputs_lock:
            self.assertEqual(KokoroHandler.received_inputs, [])
        self.assertFalse(self.sessions.exists())

    def test_allows_long_narrated_attachment_generation(self) -> None:
        output = self.root / "attachment" / "chapter.mp3"
        timings = self.root / "attachment" / "chapter-timings.json"
        environment = self.environment | {
            "TTS_INTERNAL_ATTACHMENT_GENERATION": "1",
            "TTS_OUTPUT_FILE": str(output),
            "TTS_TIMESTAMPS_FILE": str(timings),
        }

        result = subprocess.run(
            [str(self.tts_command), "--no-play", "--message", self.words(800)],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.is_file())
        with KokoroHandler.received_inputs_lock:
            self.assertEqual(len(KokoroHandler.received_inputs), 1)

    def test_does_not_exempt_retry_generation(self) -> None:
        environment = self.environment | {"TTS_INTERNAL_RETRY": "1"}

        result = self.run_primary(self.words(331), environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contains 331 words", result.stderr)
        with KokoroHandler.received_inputs_lock:
            self.assertEqual(KokoroHandler.received_inputs, [])

    def test_rejects_forwarded_remote_message_before_transport(self) -> None:
        result = subprocess.run(
            [
                str(self.tts_command),
                "remote",
                "speak",
                "--agent-name",
                "message-limit-test",
                "--subject",
                "Keeping remote spoken updates within safe limits",
                "--summary",
                "Remote TTS messages stay within the safe playback boundary.",
                "--message",
                self.words(331),
            ],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contains 331 words", result.stderr)
        self.assertNotIn("remote_transport_error", result.stderr)


if __name__ == "__main__":
    unittest.main()

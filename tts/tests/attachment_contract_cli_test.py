#!/usr/bin/env python3
"""CLI contract tests for TTS requests."""

from __future__ import annotations

from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

from tts.tests.tts_test_support import KokoroHandler


class AttachmentContractTests(unittest.TestCase):
    def setUp(self) -> None:
        with KokoroHandler.received_inputs_lock:
            KokoroHandler.received_inputs = []
            KokoroHandler.received_voices = []

    def test_rejects_removed_introduction_option(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"
        result = subprocess.run(
            [
                str(tts_command),
                "--introduction",
                "Agent example here.",
                "--message",
                "This should not run.",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Error: unknown option: --introduction", result.stderr)

    def test_requires_agent_seed_subject_and_summary(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"

        missing_agent = subprocess.run(
            [
                str(tts_command),
                "--subject",
                "Testing the required agent seed contract",
                "--summary",
                "This request is missing its agent seed.",
                "--message",
                "This should not run.",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(missing_agent.returncode, 0)
        self.assertIn("Error: --agent-name is required.", missing_agent.stderr)

        missing_subject = subprocess.run(
            [
                str(tts_command),
                "--agent-name",
                "required-fields-test",
                "--summary",
                "This request is missing its title.",
                "--message",
                "This should not run.",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(missing_subject.returncode, 0)
        self.assertIn("Error: --subject is required.", missing_subject.stderr)

        missing_summary = subprocess.run(
            [
                str(tts_command),
                "--agent-name",
                "required-fields-test",
                "--subject",
                "Required Fields",
                "--message",
                "This should not run.",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(missing_summary.returncode, 0)
        self.assertIn("Error: --summary is required.", missing_summary.stderr)

    def test_rejects_public_voice_selection(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"
        common = [
            str(tts_command),
            "--agent-name",
            "voice-contract-test",
            "--subject",
            "Testing public voice selection removal behavior",
            "--summary",
            "Public voice selection remains unavailable.",
        ]

        option = subprocess.run(
            [*common, "--voice-id", "af_nova", "--message", "This should not run."],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(option.returncode, 0)
        self.assertIn("Error: unknown option: --voice-id", option.stderr)

        positional = subprocess.run(
            [*common, "This should not run.", "af_nova"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(positional.returncode, 0)
        self.assertIn("Error: too many arguments.", positional.stderr)

    def test_runtime_accepts_short_titles_and_rejects_over_ten_words(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"
        with tempfile.TemporaryDirectory(prefix="tts-subject-tolerance-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                environment = os.environ.copy()
                environment.update(
                    {
                        "HOME": str(home),
                        "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                        "TTS_SESSIONS_ROOT": str(root / "sessions"),
                        "TTS_STATE_DIR": str(root / "state"),
                    }
                )
                accepted = subprocess.run(
                    [
                        str(tts_command),
                        "--agent-name",
                        "subject-tolerance-test",
                        "--subject",
                        "MCP Audio",
                        "--summary",
                        "A two-word title is valid.",
                        "--no-play",
                        "--message",
                        "The subject is accepted.",
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.assertEqual(accepted.returncode, 0, accepted.stderr)

                boundary = subprocess.run(
                    [
                        str(tts_command),
                        "--agent-name",
                        "subject-tolerance-test",
                        "--subject",
                        "MCP audio generation now works across every paired delivery path",
                        "--summary",
                        "A ten-word title remains valid.",
                        "--no-play",
                        "--message",
                        "The boundary title is accepted.",
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.assertEqual(boundary.returncode, 0, boundary.stderr)

                rejected = subprocess.run(
                    [
                        str(tts_command),
                        "--agent-name",
                        "subject-tolerance-test",
                        "--subject",
                        "MCP audio generation now works across every paired delivery path reliably",
                        "--summary",
                        "An eleven-word title must be rejected.",
                        "--no-play",
                        "--message",
                        "The subject is rejected.",
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("must not exceed 10 words", rejected.stderr)
            finally:
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()



if __name__ == "__main__":
    unittest.main()

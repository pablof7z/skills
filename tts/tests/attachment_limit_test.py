#!/usr/bin/env python3
"""Narrated attachment word-limit contract tests."""

from __future__ import annotations

from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from tts.scripts.tts_attachment_text import narrated_attachment_speech
from tts.tests.tts_test_support import KokoroHandler


class AttachmentLimitTests(unittest.TestCase):
    def setUp(self) -> None:
        with KokoroHandler.received_inputs_lock:
            KokoroHandler.received_inputs = []
            KokoroHandler.received_voices = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()

    def test_allows_exactly_two_thousand_narrated_words(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-attachment-limit-boundary-") as temporary:
            source = Path(temporary) / "boundary.md"
            source.write_text("word " * 2_000, encoding="utf-8")

            speech = narrated_attachment_speech("Boundary", source)

            self.assertEqual(len(speech.split()), 2_000)

    def test_rejects_oversized_root_attachment_before_synthesis(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-attachment-limit-root-") as temporary:
            root = Path(temporary)
            attachment = root / "oversized.md"
            attachment.write_text("word " * 2_001, encoding="utf-8")

            result = self.run_tts(root, "--attach", "Process sample", str(attachment))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                'narrated attachment "Process sample" contains 2001 words',
                result.stderr,
            )
            self.assertIn("enforced limit is 2000 words", result.stderr)
            self.assertIn("non-text extension", result.stderr)
            with KokoroHandler.received_inputs_lock:
                self.assertEqual(KokoroHandler.received_inputs, [])

    def test_rejects_oversized_question_attachment_before_synthesis(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-attachment-limit-question-") as temporary:
            root = Path(temporary)
            attachment = root / "oversized.txt"
            attachment.write_text("word " * 2_001, encoding="utf-8")
            bundle = {
                "questions": [
                    {
                        "short_title": "Inspect evidence?",
                        "title": "Should the evidence be inspected?",
                        "attachments": [{"label": "Detailed evidence", "path": str(attachment)}],
                        "suggestions": [],
                    }
                ]
            }

            result = self.run_tts(root, "--ask", json.dumps(bundle), "--wait", "1s")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                'narrated attachment "Detailed evidence" contains 2001 words',
                result.stderr,
            )
            with KokoroHandler.received_inputs_lock:
                self.assertEqual(KokoroHandler.received_inputs, [])

    def test_keeps_large_non_text_artifact_without_narrating_it(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-attachment-limit-file-") as temporary:
            root = Path(temporary)
            attachment = root / "process.sample"
            attachment.write_text("word " * 2_500, encoding="utf-8")

            result = self.run_tts(root, "--attach", "Full process sample", str(attachment))

            self.assertEqual(result.returncode, 0, result.stderr)
            manifest_path = next((root / "sessions").glob("*/briefs/*/attachments/manifest.json"))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest[0]["kind"], "file")
            self.assertEqual(manifest[0]["status"], "ready")
            with KokoroHandler.received_inputs_lock:
                self.assertEqual(len(KokoroHandler.received_inputs), 1)

    def run_tts(self, root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        repository = Path(__file__).resolve().parents[2]
        home = root / "home"
        home.mkdir()
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(home),
                "KOKORO_API_ENDPOINT": (
                    f"http://127.0.0.1:{self.server.server_port}/v1/audio/speech"
                ),
                "TTS_SESSIONS_ROOT": str(root / "sessions"),
                "TTS_STATE_DIR": str(root / "state"),
            }
        )
        playback_arguments = [] if "--ask" in arguments else ["--no-play"]
        return subprocess.run(
            [
                str(repository / "tts" / "scripts" / "tts"),
                *playback_arguments,
                "--agent-name",
                "attachment-limit-test",
                "--subject",
                "Attachment Limit",
                "--summary",
                "Narrated attachments remain within a safe generation budget.",
                "--message",
                "The primary update is concise.",
                *arguments,
            ],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=15,
        )


if __name__ == "__main__":
    unittest.main()

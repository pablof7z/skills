#!/usr/bin/env python3
"""Markdown-to-speech normalization and CLI contract tests."""

from __future__ import annotations

from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from tts.scripts.tts_speech_text import markdown_for_speech
from tts.tests.tts_test_support import KokoroHandler


class SpeechTextUnitTests(unittest.TestCase):
    def test_headers_create_spoken_paragraphs_without_markers(self) -> None:
        source = "# A request starts anywhere\n\nA local agent calls the CLI."

        speech = markdown_for_speech(source)

        self.assertEqual(
            speech,
            "A request starts anywhere.\n\nA local agent calls the CLI.",
        )
        self.assertNotIn("#", speech)

    def test_keeps_non_markdown_hashes_inside_heading_text(self) -> None:
        self.assertEqual(markdown_for_speech("# C# integration"), "C# integration.")

    def test_normalizes_common_markdown_and_preserves_block_pauses(self) -> None:
        source = """## **Choices**

- Read the [proposal](https://example.com)
- Inspect `status`

> Then decide
"""

        speech = markdown_for_speech(source)

        self.assertEqual(
            speech,
            "Choices.\n\nRead the proposal.\n\nInspect status.\n\nThen decide.",
        )

    def test_omits_tagged_code_and_keeps_untagged_code(self) -> None:
        source = """Before.

```swift
let hidden = true
```
["The sample returns true."]

```
echo hello
```
"""

        speech = markdown_for_speech(source)

        self.assertNotIn("hidden", speech)
        self.assertIn("The sample returns true.", speech)
        self.assertIn("echo hello.", speech)


class SpeechTextCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-speech-text-")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.root / "state"
        self.repository = Path(__file__).resolve().parents[2]
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
        self.temporary.cleanup()

    def test_keeps_display_markdown_and_sends_spoken_structure_to_kokoro(self) -> None:
        message = "# A request starts anywhere\n\nA local agent calls the CLI."
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(self.home),
                "KOKORO_API_ENDPOINT": (
                    f"http://127.0.0.1:{self.server.server_port}/v1/audio/speech"
                ),
                "TTS_MACOS_MENU": "0",
                "TTS_SESSIONS_ROOT": str(self.root / "sessions"),
                "TTS_STATE_DIR": str(self.state),
            }
        )

        result = subprocess.run(
            [
                str(self.repository / "tts" / "scripts" / "tts"),
                "--agent-name",
                "speech-text-test",
                "--subject",
                "Markdown Speech",
                "--summary",
                "Markdown remains visible while spoken structure sounds natural.",
                "--no-play",
                "--message",
                message,
            ],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=15,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        item = json.loads(
            (self.state / "items" / f"{output['id']}.json").read_text(encoding="utf-8")
        )
        self.assertEqual(item["text"], message)
        with KokoroHandler.received_inputs_lock:
            self.assertEqual(
                KokoroHandler.received_inputs,
                [
                    "Markdown Speech. A request starts anywhere.\n\n"
                    "A local agent calls the CLI."
                ],
            )


if __name__ == "__main__":
    unittest.main()

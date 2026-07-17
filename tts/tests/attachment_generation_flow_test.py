#!/usr/bin/env python3
"""Generation lifecycle tests for TTS requests."""

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

from tts.tests.tts_test_support import (
    BlockingAttachmentKokoroHandler,
    BlockingKokoroHandler,
    FailingKokoroHandler,
    KokoroHandler,
)


class AttachmentGenerationFlowTests(unittest.TestCase):
    def setUp(self) -> None:
        with KokoroHandler.received_inputs_lock:
            KokoroHandler.received_inputs = []
            KokoroHandler.received_voices = []

    def test_publishes_generating_item_before_audio_is_ready(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"
        with tempfile.TemporaryDirectory(prefix="tts-generating-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            sessions = root / "sessions"
            state = root / "state"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_uname = fake_bin / "uname"
            fake_uname.write_text("#!/bin/sh\nprintf 'Darwin\\n'\n", encoding="utf-8")
            fake_uname.chmod(0o755)
            fake_menu = root / "tts-menu"
            fake_menu.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_menu.chmod(0o755)

            BlockingKokoroHandler.request_started = threading.Event()
            BlockingKokoroHandler.release_response = threading.Event()
            server = ThreadingHTTPServer(("127.0.0.1", 0), BlockingKokoroHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            process: subprocess.Popen[str] | None = None
            try:
                environment = os.environ.copy()
                environment.update(
                    {
                        "HOME": str(home),
                        "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                        "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                        "TTS_MACOS_MENU": "1",
                        "TTS_MENU_COMMAND": str(fake_menu),
                        "TTS_SESSIONS_ROOT": str(sessions),
                        "TTS_STATE_DIR": str(state),
                        "TERM_PROGRAM": "iTerm.app",
                        "ITERM_SESSION_ID": "w5t13p3:9473B74C-9371-4C44-B34C-84F40E3D2F04",
                    }
                )
                process = subprocess.Popen(
                    [
                        str(tts_command),
                        "--message",
                        "The player should show this while it is generating.",
                        "--agent-name",
                        "agent-foreground-test",
                        "--subject",
                        "Foreground TTS generation remains clearly observable",
                        "--summary",
                        "The player publishes the update\nbefore audio generation finishes.",
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )

                self.assertTrue(BlockingKokoroHandler.request_started.wait(timeout=5))
                item_files = list((state / "items").glob("*.json"))
                self.assertEqual(len(item_files), 1)
                item_path = item_files[0]
                generating = json.loads(item_path.read_text(encoding="utf-8"))
                self.assertEqual(generating["status"], "generating")
                self.assertEqual(
                    generating["summary"],
                    "The player publishes the update before audio generation finishes.",
                )
                self.assertTrue(generating["playback_requested"])
                self.assertEqual(
                    generating["iterm_session_id"],
                    "w5t13p3:9473B74C-9371-4C44-B34C-84F40E3D2F04",
                )
                self.assertFalse(Path(generating["output_file"]).exists())
                self.assertFalse((state / "playback-admissions").exists())
                self.assertIsNone(process.poll())

                BlockingKokoroHandler.release_response.set()
                stdout, stderr = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, stderr)
                queued = json.loads(item_path.read_text(encoding="utf-8"))
                self.assertEqual(queued["status"], "queued")
                self.assertEqual(queued["iterm_session_id"], generating["iterm_session_id"])
                self.assertEqual(queued["agent_name"], "agent-foreground-test")
                self.assertEqual(queued["summary"], generating["summary"])
                self.assertIsNotNone(queued["generation_duration"])
                self.assertTrue(queued["is_unheard"])
                self.assertTrue(Path(queued["output_file"]).is_file())
                admission = json.loads(
                    (state / "playback-admissions" / f"{queued['id']}.json").read_text(
                        encoding="utf-8"
                    )
                )
                self.assertEqual(admission["item_id"], queued["id"])
                with KokoroHandler.received_inputs_lock:
                    spoken = KokoroHandler.received_inputs[-1]
                self.assertTrue(
                    spoken.startswith("Foreground TTS generation remains clearly observable.")
                )
                self.assertNotIn("agent-foreground-test", spoken)
                self.assertNotIn(generating["summary"], spoken)
            finally:
                BlockingKokoroHandler.release_response.set()
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=2)
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()

    def test_marks_visible_generating_item_failed_when_synthesis_fails(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"
        with tempfile.TemporaryDirectory(prefix="tts-generating-failure-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            state = root / "state"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_uname = fake_bin / "uname"
            fake_uname.write_text("#!/bin/sh\nprintf 'Darwin\\n'\n", encoding="utf-8")
            fake_uname.chmod(0o755)
            fake_menu = root / "tts-menu"
            fake_menu.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_menu.chmod(0o755)

            server = ThreadingHTTPServer(("127.0.0.1", 0), FailingKokoroHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                environment = os.environ.copy()
                environment.update(
                    {
                        "HOME": str(home),
                        "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                        "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                        "TTS_MACOS_MENU": "1",
                        "TTS_MENU_COMMAND": str(fake_menu),
                        "TTS_STATE_DIR": str(state),
                    }
                )
                result = subprocess.run(
                    [
                        str(tts_command),
                        "--agent-name",
                        "failure-test",
                        "--subject",
                        "Testing visible TTS generation failure handling",
                        "--summary",
                        "Failed synthesis remains visible with a retry action.",
                        "--message",
                        "This request will fail.",
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                    timeout=15,
                )

                self.assertNotEqual(result.returncode, 0)
                item_files = list((state / "items").glob("*.json"))
                self.assertEqual(len(item_files), 1, result.stderr)
                failed = json.loads(item_files[0].read_text(encoding="utf-8"))
                self.assertEqual(failed["status"], "failed")
                self.assertEqual(failed["error"], "TTS request failed with HTTP 500")
                self.assertEqual(failed["retry_command"], str(tts_command))
                self.assertIsNotNone(failed["generation_duration"])
                self.assertTrue(failed["is_unheard"])
                self.assertIsNotNone(failed["completed_at"])
            finally:
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()

    def test_waits_for_narrated_attachment_generation_before_returning(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"
        with tempfile.TemporaryDirectory(prefix="tts-foreground-attachments-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            state = root / "state"
            markdown = root / "details.md"
            markdown.write_text("# Details\n\nNarrate this before returning.\n", encoding="utf-8")
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_uname = fake_bin / "uname"
            fake_uname.write_text("#!/bin/sh\nprintf 'Darwin\\n'\n", encoding="utf-8")
            fake_uname.chmod(0o755)
            fake_menu = root / "tts-menu"
            fake_menu.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_menu.chmod(0o755)

            BlockingAttachmentKokoroHandler.request_count = 0
            BlockingAttachmentKokoroHandler.attachment_request_started = threading.Event()
            BlockingAttachmentKokoroHandler.release_attachment_response = threading.Event()
            server = ThreadingHTTPServer(("127.0.0.1", 0), BlockingAttachmentKokoroHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            process: subprocess.Popen[str] | None = None
            try:
                environment = os.environ.copy()
                environment.update(
                    {
                        "HOME": str(home),
                        "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                        "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                        "TTS_MACOS_MENU": "1",
                        "TTS_MENU_COMMAND": str(fake_menu),
                        "TTS_SESSIONS_ROOT": str(root / "sessions"),
                        "TTS_STATE_DIR": str(state),
                    }
                )
                process = subprocess.Popen(
                    [
                        str(tts_command),
                        "--message",
                        "The primary update is ready.",
                        "--agent-name",
                        "attachment-wait-test",
                        "--subject",
                        "Waiting for narrated attachment generation completion",
                        "--summary",
                        "The command waits until narrated attachments finish generating.",
                        "--attach",
                        "Details",
                        str(markdown),
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )

                self.assertTrue(
                    BlockingAttachmentKokoroHandler.attachment_request_started.wait(timeout=5)
                )
                item_path = next((state / "items").glob("*.json"))
                preparing = json.loads(item_path.read_text(encoding="utf-8"))
                self.assertEqual(preparing["attachments"][0]["status"], "preparing")
                self.assertIsNone(process.poll())

                BlockingAttachmentKokoroHandler.release_attachment_response.set()
                stdout, stderr = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, stderr)
                ready = json.loads(item_path.read_text(encoding="utf-8"))
                self.assertEqual(ready["attachments"][0]["status"], "ready")
                self.assertIn("Prepared narrated TTS attachments.", stderr)
                with KokoroHandler.received_inputs_lock:
                    self.assertEqual(len(KokoroHandler.received_voices), 2)
                    self.assertEqual(len(set(KokoroHandler.received_voices)), 1)
            finally:
                BlockingAttachmentKokoroHandler.release_attachment_response.set()
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=2)
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()

    def test_normalizes_literal_newlines_before_display_and_speech(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"
        with tempfile.TemporaryDirectory(prefix="tts-literal-newlines-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            state = root / "state"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_uname = fake_bin / "uname"
            fake_uname.write_text("#!/bin/sh\nprintf 'Darwin\\n'\n", encoding="utf-8")
            fake_uname.chmod(0o755)
            fake_menu = root / "tts-menu"
            fake_menu.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_menu.chmod(0o755)
            server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                environment = os.environ.copy()
                environment.update(
                    {
                        "HOME": str(home),
                        "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                        "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                        "TTS_MACOS_MENU": "1",
                        "TTS_MENU_COMMAND": str(fake_menu),
                        "TTS_STATE_DIR": str(state),
                    }
                )
                result = subprocess.run(
                    [
                        str(tts_command),
                        "--message",
                        r"First paragraph.\n\nSecond paragraph.",
                        "--agent-name",
                        "newline-test",
                        "--subject",
                        "Normalizing literal newlines across visible spoken text",
                        "--summary",
                        "Literal newline sequences become natural spoken line breaks.",
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=True,
                )

                item_path = next((state / "items").glob("*.json"))
                item = json.loads(item_path.read_text(encoding="utf-8"))
                self.assertEqual(item["text"], "First paragraph.\n\nSecond paragraph.")
                with KokoroHandler.received_inputs_lock:
                    spoken = KokoroHandler.received_inputs[-1]
                self.assertNotIn(r"\n", spoken)
                self.assertIn("First paragraph.", spoken)
                self.assertIn("Second paragraph.", spoken)
            finally:
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()



if __name__ == "__main__":
    unittest.main()

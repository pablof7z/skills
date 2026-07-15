#!/usr/bin/env python3
"""End-to-end contract test for durable TTS brief attachments."""

from __future__ import annotations

import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest


class KokoroHandler(BaseHTTPRequestHandler):
    received_inputs: list[str] = []
    received_inputs_lock = threading.Lock()

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        with self.received_inputs_lock:
            self.received_inputs.append(request["input"])
        payload = json.dumps(
            {
                "audio": base64.b64encode(b"test-mp3-audio").decode("ascii"),
                "timestamps": [{"word": "Test", "start_time": 0.0, "end_time": 0.2}],
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        pass


class BlockingKokoroHandler(KokoroHandler):
    request_started = threading.Event()
    release_response = threading.Event()

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.request_started.set()
        self.release_response.wait(timeout=5)
        super().do_POST()


class FailingKokoroHandler(KokoroHandler):
    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(500)
        self.send_header("Content-Length", "0")
        self.end_headers()


class AttachmentFlowTests(unittest.TestCase):
    def setUp(self) -> None:
        with KokoroHandler.received_inputs_lock:
            KokoroHandler.received_inputs = []

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
                        "--voice-id",
                        "af_nova",
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
                    generating["iterm_session_id"],
                    "w5t13p3:9473B74C-9371-4C44-B34C-84F40E3D2F04",
                )
                self.assertFalse(Path(generating["output_file"]).exists())
                self.assertIsNone(process.poll())

                BlockingKokoroHandler.release_response.set()
                stdout, stderr = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, stderr)
                queued = json.loads(item_path.read_text(encoding="utf-8"))
                self.assertEqual(queued["status"], "queued")
                self.assertEqual(queued["iterm_session_id"], generating["iterm_session_id"])
                self.assertTrue(Path(queued["output_file"]).is_file())
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
                    [str(tts_command), "--voice-id", "af_nova", "This request will fail."],
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
                self.assertEqual(failed["error"], "Speech generation failed.")
                self.assertIsNotNone(failed["completed_at"])
            finally:
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
                        "--voice-id",
                        "af_nova",
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

    def test_builds_durable_brief_and_prepares_narration(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"
        with tempfile.TemporaryDirectory(prefix="tts-attachments-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            sessions = root / "sessions"
            state = root / "state"
            markdown = root / "why.md"
            markdown.write_text("# Why this matters\n\n- Durable context stays nearby.\n", encoding="utf-8")
            image = root / "screen.png"
            image.write_bytes(b"\x89PNG\r\n\x1a\nfixture")
            vector = root / "mockup.svg"
            vector.write_text('<svg xmlns="http://www.w3.org/2000/svg"/>', encoding="utf-8")
            diagram = root / "flow.mmd"
            diagram.write_text("flowchart LR\n  A --> B\n", encoding="utf-8")
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
                        "TTS_MENU_COMMAND": str(fake_menu),
                        "TTS_SESSIONS_ROOT": str(sessions),
                        "TTS_STATE_DIR": str(state),
                        "TTS_SESSION_ID": "Thread / Unsafe",
                    }
                )
                result = subprocess.run(
                    [
                        str(tts_command),
                        "--message",
                        "The primary update is ready.",
                        "--voice-id",
                        "af_nova",
                        "--attach",
                        "Why this matters",
                        str(markdown),
                        "--attach",
                        "Screenshot",
                        str(image),
                        "--attach",
                        "Vector mockup",
                        str(vector),
                        "--attach",
                        "Architecture flow",
                        str(diagram),
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=True,
                )

                item_files = list((state / "items").glob("*.json"))
                self.assertEqual(len(item_files), 1, result.stderr)
                item_path = item_files[0]
                deadline = time.monotonic() + 10
                while True:
                    item = json.loads(item_path.read_text(encoding="utf-8"))
                    narrated = item["attachments"][0]
                    if narrated["status"] != "preparing" or time.monotonic() >= deadline:
                        break
                    time.sleep(0.05)

                brief = sessions / "thread-unsafe" / "briefs" / item["id"]
                self.assertEqual(Path(item["output_file"]), brief / "message.mp3")
                self.assertTrue((brief / "message.mp3").is_file())
                self.assertTrue((brief / "message-timings.json").is_file())
                self.assertTrue((brief / "attachments" / "manifest.json").is_file())
                self.assertEqual(narrated["status"], "ready")
                self.assertIsNone(narrated["text"])
                self.assertTrue(Path(narrated["source_file"]).is_file())
                self.assertTrue(Path(narrated["audio_file"]).is_file())
                self.assertEqual(item["attachments"][1]["kind"], "image")
                self.assertTrue(Path(item["attachments"][1]["source_file"]).is_file())
                self.assertEqual(item["attachments"][2]["kind"], "image")
                self.assertTrue(Path(item["attachments"][2]["source_file"]).is_file())
                self.assertEqual(item["attachments"][3]["kind"], "diagram")
                self.assertEqual(item["attachments"][3]["text"], "flowchart LR\n  A --> B\n")
            finally:
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()

    def test_language_tagged_code_is_kept_visual_but_omitted_from_speech(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        tts_command = repository / "tts" / "scripts" / "tts"
        message = """Before the sample.

```swift
let visualOnly = 42
```
[\"The sample assigns a value.\"]

After the sample."""

        with tempfile.TemporaryDirectory(prefix="tts-code-speech-") as temporary:
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
                subprocess.run(
                    [
                        str(tts_command),
                        "--no-play",
                        "--voice-id",
                        "af_nova",
                        "--message",
                        message,
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=True,
                )

                with KokoroHandler.received_inputs_lock:
                    spoken = KokoroHandler.received_inputs[-1]
                self.assertNotIn("visualOnly", spoken)
                self.assertNotIn("```", spoken)
                self.assertIn("The sample assigns a value.", spoken)
                self.assertIn("Before the sample.", spoken)
                self.assertIn("After the sample.", spoken)
            finally:
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()

    def test_worker_waits_for_attachment_metadata_race(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        worker = repository / "tts" / "scripts" / "tts-attachment-worker"
        with tempfile.TemporaryDirectory(prefix="tts-attachment-race-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            attachment_directory = root / "attachment"
            attachment_directory.mkdir()
            source = attachment_directory / "source.md"
            source.write_text("# Delayed attachment\n\nThe worker should claim this after it appears.", encoding="utf-8")
            item_path = root / "item.json"
            item = {"voice": "af_nova", "attachments": None}
            item_path.write_text(json.dumps(item), encoding="utf-8")

            server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                environment = os.environ.copy()
                environment.update(
                    {
                        "HOME": str(home),
                        "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                    }
                )
                process = subprocess.Popen(
                    [str(worker), str(item_path)],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                time.sleep(0.2)
                item["attachments"] = [
                    {
                        "id": "01-delayed",
                        "label": "Delayed attachment",
                        "kind": "narrated_text",
                        "status": "preparing",
                        "source_file": str(source),
                        "audio_file": str(attachment_directory / "narration.mp3"),
                        "word_timings": None,
                        "error": None,
                    }
                ]
                replacement = item_path.with_suffix(".new")
                replacement.write_text(json.dumps(item), encoding="utf-8")
                replacement.replace(item_path)
                stdout, stderr = process.communicate(timeout=15)

                self.assertEqual(process.returncode, 0, stderr)
                updated = json.loads(item_path.read_text(encoding="utf-8"))
                self.assertEqual(updated["attachments"][0]["status"], "ready")
                self.assertTrue(Path(updated["attachments"][0]["audio_file"]).is_file())
                self.assertIn("Claimed 1 narrated attachment", stdout)
                self.assertIn("Narrated attachment ready", stdout)
            finally:
                server.shutdown()
                thread.join(timeout=2)
                server.server_close()


if __name__ == "__main__":
    unittest.main()

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
    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
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


class AttachmentFlowTests(unittest.TestCase):
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

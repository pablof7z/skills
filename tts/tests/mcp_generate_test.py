#!/usr/bin/env python3
"""Local MCP generation remains no-play and returns a hosted MP3."""

from __future__ import annotations

import asyncio
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_mcp_adapter import TTSAdapter
from tts_mcp_config import MCPConfig
from tts.tests.tts_test_support import KokoroHandler


class UploadHandler(BaseHTTPRequestHandler):
    uploads: list[bytes] = []

    def do_PUT(self) -> None:  # noqa: N802
        payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        type(self).uploads.append(payload)
        sha256 = hashlib.sha256(payload).hexdigest()
        body = json.dumps({
            "url": f"https://blossom.primal.net/{sha256}.mp3",
            "sha256": sha256,
            "size": len(payload),
            "type": "audio/mpeg",
            "uploaded": int(time.time()),
        }).encode("utf-8")
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        pass


class MCPGenerateTests(unittest.TestCase):
    def test_local_generate_uploads_and_omits_local_path(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-mcp-generate-") as temporary:
            root = Path(temporary)
            (root / "home").mkdir()
            kokoro = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
            blossom = ThreadingHTTPServer(("127.0.0.1", 0), UploadHandler)
            threads = [
                threading.Thread(target=kokoro.serve_forever, daemon=True),
                threading.Thread(target=blossom.serve_forever, daemon=True),
            ]
            UploadHandler.uploads = []
            for thread in threads:
                thread.start()
            environment = {
                "HOME": str(root / "home"),
                "TTS_STATE_DIR": str(root / "state"),
                "TTS_SESSIONS_ROOT": str(root / "sessions"),
                "TTS_REMOTE_TRANSPORT": "file",
                "TTS_REMOTE_TRANSPORT_FILE": str(root / "transport.jsonl"),
                "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{kokoro.server_port}/v1/audio/speech",
                "TTS_BLOSSOM_SERVER": f"http://127.0.0.1:{blossom.server_port}",
                "TTS_MACOS_MENU": "0",
            }
            try:
                with patch.dict(os.environ, environment, clear=False):
                    result = asyncio.run(TTSAdapter(MCPConfig(
                        skill_dir=ROOT / "tts",
                        route="local",
                    )).generate(
                        agent_name="MCP agent",
                        subject="Generate a hosted local audio file",
                        summary="A local MCP request should return hosted audio.",
                        message="Return this as a Blossom-hosted MP3.",
                        wait_seconds=30,
                    ))
                self.assertEqual(result["status"], "uploaded")
                self.assertTrue(result["url"].startswith("https://blossom.primal.net/"))
                self.assertNotIn("output_file", result)
                self.assertEqual(UploadHandler.uploads, [b"test-mp3-audio"])
                items = list((root / "state" / "items").glob("*.json"))
                item = json.loads(items[0].read_text())
                self.assertEqual(item["status"], "generated")
                self.assertEqual(item["summary"], "A local MCP request should return hosted audio.")
            finally:
                for server, thread in zip((kokoro, blossom), threads):
                    server.shutdown()
                    thread.join(timeout=2)
                    server.server_close()


if __name__ == "__main__":
    unittest.main()

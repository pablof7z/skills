#!/usr/bin/env python3
"""End-to-end paired generation and Blossom return contract."""

from __future__ import annotations

import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

from tts.tests.tts_test_support import KokoroHandler


class BlossomHandler(BaseHTTPRequestHandler):
    uploads: list[dict[str, object]] = []

    def do_PUT(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(length)
        sha256 = hashlib.sha256(payload).hexdigest()
        type(self).uploads.append({
            "payload": payload,
            "authorization": self.headers.get("Authorization"),
            "sha256": self.headers.get("X-SHA-256"),
        })
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


class RemoteGenerationRoundTripTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-generation-")
        self.root = Path(self.temporary.name)
        self.laptop = self.root / "laptop"
        self.server = self.root / "server"
        (self.laptop / "home").mkdir(parents=True)
        (self.server / "home").mkdir(parents=True)
        self.transport_file = self.root / "transport.jsonl"
        self.tts = Path(__file__).resolve().parents[1] / "scripts" / "tts"
        self.kokoro = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        self.blossom = ThreadingHTTPServer(("127.0.0.1", 0), BlossomHandler)
        self.threads = [
            threading.Thread(target=self.kokoro.serve_forever, daemon=True),
            threading.Thread(target=self.blossom.serve_forever, daemon=True),
        ]
        BlossomHandler.uploads = []
        for thread in self.threads:
            thread.start()

    def tearDown(self) -> None:
        self.run_tts("daemon", "stop", state=self.laptop, check=False)
        for server, thread in zip((self.kokoro, self.blossom), self.threads):
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()
        self.temporary.cleanup()

    def environment(self, state: Path) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update({
            "HOME": str(state / "home"),
            "TTS_STATE_DIR": str(state),
            "TTS_SESSIONS_ROOT": str(state / "sessions"),
            "TTS_REMOTE_TRANSPORT": "file",
            "TTS_REMOTE_TRANSPORT_FILE": str(self.transport_file),
            "TTS_REMOTE_NO_MENU": "1",
            "TTS_GROUP_CONFIRM_TIMEOUT_SECONDS": "3",
        })
        return environment

    def run_tts(
        self,
        *arguments: str,
        state: Path,
        env: dict[str, str] | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.tts), *arguments],
            env=env or self.environment(state),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def pair(self) -> str:
        offer = json.loads(self.run_tts("pair", "offer", state=self.laptop).stdout)
        self.run_tts("daemon", "start", state=self.laptop)
        connected = json.loads(
            self.run_tts(
                "pair", "connect", "--code", offer["pair_code"], state=self.server,
            ).stdout
        )
        self.run_tts("daemon", "stop", state=self.laptop)
        return str(connected["peer"]["pubkey"])

    def test_generate_runs_on_paired_computer_and_returns_blossom_mp3(self) -> None:
        peer = self.pair()
        remote = subprocess.Popen(
            [
                str(self.tts), "remote", "generate", "--peer", peer,
                "--agent-name", "MCP agent",
                "--subject", "Generate the hosted paired audio result",
                "--summary", "The paired computer should generate and host this audio.",
                "--message", "This MP3 is generated on the paired computer.",
                "--wait", "10s",
            ],
            env=self.environment(self.server),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            request = self.wait_for_generation_request()
            environment = self.environment(self.laptop)
            environment.update({
                "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{self.kokoro.server_port}/v1/audio/speech",
                "TTS_BLOSSOM_SERVER": f"http://127.0.0.1:{self.blossom.server_port}",
                "TTS_MACOS_MENU": "0",
            })
            daemon = self.run_tts(
                "daemon", "run", "--once", "--max-events", "1",
                state=self.laptop,
                env=environment,
            )
            stdout, stderr = remote.communicate(timeout=10)
            self.assertEqual(remote.returncode, 0, stderr)
            self.assertEqual(json.loads(daemon.stdout)["processed"], 1)
            result = json.loads(stdout)
            self.assertEqual(result["status"], "uploaded")
            self.assertTrue(result["url"].startswith("https://blossom.primal.net/"))
            self.assertNotIn("output_file", result)
            self.assertEqual(BlossomHandler.uploads[0]["payload"], b"test-mp3-audio")
            self.assertEqual(BlossomHandler.uploads[0]["sha256"], result["sha256"])
            event = self.decoded_authorization(BlossomHandler.uploads[0]["authorization"])
            self.assertIn(["t", "upload"], event["tags"])
            self.assertIn(["x", result["sha256"]], event["tags"])
            self.assertIn(["action", "generate"], request["tags"])
            item = json.loads((self.laptop / "items" / f"{request['id']}.json").read_text())
            self.assertEqual(item["status"], "generated")
            self.assertEqual(
                item["summary"],
                "The paired computer should generate and host this audio.",
            )
        finally:
            if remote.poll() is None:
                remote.kill()
                remote.communicate(timeout=2)

    def test_generate_timeout_is_an_error_instead_of_a_non_upload_result(self) -> None:
        peer = self.pair()
        completed = self.run_tts(
            "remote", "generate", "--peer", peer,
            "--agent-name", "MCP agent",
            "--subject", "Require a hosted result",
            "--summary", "A pending generation result must be treated as an error.",
            "--message", "Do not return pending as a generation result.",
            "--wait", "0.1s",
            state=self.server,
            check=False,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(json.loads(completed.stderr)["status"], "pending")

    def wait_for_generation_request(self) -> dict[str, object]:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.transport_file.is_file():
                for line in reversed(self.transport_file.read_text().splitlines()):
                    event = json.loads(line)
                    if ["action", "generate"] in event.get("tags", []):
                        return event
            time.sleep(0.05)
        self.fail("paired generation request was not published")

    @staticmethod
    def decoded_authorization(value: object) -> dict[str, object]:
        encoded = str(value).removeprefix("Nostr ")
        encoded += "=" * (-len(encoded) % 4)
        return json.loads(base64.urlsafe_b64decode(encoded))


if __name__ == "__main__":
    unittest.main()

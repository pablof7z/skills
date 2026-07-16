#!/usr/bin/env python3
"""Contracts for remote TTS request and daemon commands."""

from __future__ import annotations

from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from tts.tests.tts_test_support import KokoroHandler


class RemoteDaemonCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-daemon-")
        self.state = Path(self.temporary.name)
        (self.state / "home").mkdir()
        repository = Path(__file__).resolve().parents[2]
        self.tts = repository / "tts" / "scripts" / "tts"
        self.transport_file = self.state / "transport.jsonl"
        self.environment = os.environ.copy()
        self.environment["HOME"] = str(self.state / "home")
        self.environment["TTS_STATE_DIR"] = str(self.state)
        self.environment["TTS_SESSIONS_ROOT"] = str(self.state / "sessions")
        self.environment["TTS_REMOTE_TRANSPORT"] = "file"
        self.environment["TTS_REMOTE_TRANSPORT_FILE"] = str(self.transport_file)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_tts(
        self,
        *arguments: str,
        env: dict[str, str] | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        merged = self.environment.copy()
        if env:
            merged.update(env)
        return subprocess.run(
            [str(self.tts), *arguments],
            env=merged,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def pair(self) -> dict[str, object]:
        offer = json.loads(
            self.run_tts(
                "pair", "offer",
                "--relay", "file://transport",
                "--laptop-pubkey", "laptop-daemon",
            ).stdout
        )
        return json.loads(self.run_tts("pair", "connect", "--code", json.dumps(offer["pair_code"])).stdout)

    def test_remote_request_uses_exact_agent_nsec_with_stable_backend_reply_endpoint(self) -> None:
        connected = self.pair()
        backend_pubkey = connected["backend_pubkey"]
        result = self.run_tts(
            "remote", "speak",
            "--peer", "laptop-daemon",
            "--agent-name", "agent one",
            "--subject", "Remote signer selection test case",
            "--message", "Text speech request.",
            env={"AGENT_NSEC": "nsec-agent-secret"},
        )
        output = json.loads(result.stdout)
        self.assertEqual(output["status"], "sent")

        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        request = events[-1]
        self.assertEqual(request["kind"], 9)
        self.assertIn(["p", "laptop-daemon"], request["tags"])
        self.assertIn(["h", "tts"], request["tags"])
        content = json.loads(request["content"])
        self.assertEqual(content["signer"]["source"], "AGENT_NSEC")
        self.assertEqual(content["signer"]["nsec"], "nsec-agent-secret")
        self.assertEqual(content["backend"]["pubkey"], backend_pubkey)
        self.assertEqual(content["request_id"], output["request_id"])

    def test_daemon_materializes_text_request_through_existing_tts_queue(self) -> None:
        self.pair()
        server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.run_tts(
                "remote", "speak",
                "--peer", "laptop-daemon",
                "--agent-name", "remote agent",
                "--subject", "Remote text playback through queue",
                "--message", "Remote text works.",
            )
            result = self.run_tts(
                "daemon", "run", "--once", "--max-events", "1",
                env={
                    "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                    "TTS_REMOTE_DAEMON_NO_PLAY": "1",
                },
            )
            self.assertEqual(json.loads(result.stdout)["processed"], 1)
            items = list((self.state / "items").glob("*.json"))
            self.assertEqual(len(items), 1)
            item = json.loads(items[0].read_text())
            self.assertEqual(item["status"], "generated")
            self.assertEqual(item["remote_request"]["transport"], "kind:9")
            self.assertEqual(item["agent_name"], "remote agent")

            events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
            reply = events[-1]
            self.assertEqual(reply["kind"], 9)
            self.assertIn(["e", item["remote_request"]["event_id"]], reply["tags"])
            self.assertIn(["h", "tts"], reply["tags"])
            self.assertEqual(json.loads(reply["content"])["status"], "accepted")
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_daemon_rejects_inaccessible_remote_attachments_with_structured_guidance(self) -> None:
        self.pair()
        self.run_tts(
            "remote", "speak",
            "--peer", "laptop-daemon",
            "--agent-name", "remote agent",
            "--subject", "Remote attachment safe failure",
            "--message", "Attachment should fail safely.",
            "--attach", "Missing file", "/not/on/this/laptop.txt",
        )
        result = self.run_tts("daemon", "run", "--once", "--max-events", "1")
        self.assertEqual(json.loads(result.stdout)["processed"], 1)
        self.assertFalse((self.state / "items").exists())

        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        reply = json.loads(events[-1]["content"])
        self.assertEqual(reply["status"], "rejected")
        self.assertEqual(reply["error"]["code"], "remote_attachment_unavailable")
        self.assertIn("send text only", reply["error"]["guidance"].lower())

    def test_daemon_lifecycle_status_uses_durable_state(self) -> None:
        status = json.loads(self.run_tts("daemon", "status").stdout)
        self.assertEqual(status["running"], False)

        started = json.loads(self.run_tts("daemon", "start", "--dry-run").stdout)
        self.assertEqual(started["status"], "started")
        self.assertEqual(json.loads(self.run_tts("daemon", "status").stdout)["running"], True)

        stopped = json.loads(self.run_tts("daemon", "stop").stdout)
        self.assertEqual(stopped["status"], "stopped")
        self.assertEqual(json.loads(self.run_tts("daemon", "status").stdout)["running"], False)


if __name__ == "__main__":
    unittest.main()

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
import time
import unittest

from tts.tests.tts_test_support import KokoroHandler


class RemoteDaemonCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-daemon-")
        self.state = Path(self.temporary.name)
        self.laptop_state = self.state / "laptop"
        self.server_state = self.state / "server"
        (self.laptop_state / "home").mkdir(parents=True)
        (self.server_state / "home").mkdir(parents=True)
        repository = Path(__file__).resolve().parents[2]
        self.tts = repository / "tts" / "scripts" / "tts"
        self.transport_file = self.state / "transport.jsonl"
        self.base_environment = os.environ.copy()
        self.base_environment["TTS_REMOTE_TRANSPORT"] = "file"
        self.base_environment["TTS_REMOTE_TRANSPORT_FILE"] = str(self.transport_file)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def env_for(self, state: Path) -> dict[str, str]:
        environment = self.base_environment.copy()
        environment["HOME"] = str(state / "home")
        environment["TTS_STATE_DIR"] = str(state)
        environment["TTS_SESSIONS_ROOT"] = str(state / "sessions")
        return environment

    def run_tts(
        self,
        *arguments: str,
        state: Path | None = None,
        env: dict[str, str] | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        merged = self.env_for(state or self.laptop_state)
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
            ).stdout
        )
        connected = json.loads(self.run_tts("pair", "connect", "--code", json.dumps(offer["pair_code"]), state=self.server_state).stdout)
        self.run_tts("daemon", "run", "--once", "--max-events", "1")
        connected["laptop_pubkey"] = offer["pair_code"]["laptop_pubkey"]
        return connected

    def test_remote_request_never_serializes_signer_secret_and_keeps_stable_backend_reply_endpoint(self) -> None:
        connected = self.pair()
        backend_pubkey = connected["backend_pubkey"]
        laptop_pubkey = connected["laptop_pubkey"]
        result = self.run_tts(
            "remote", "speak",
            "--peer", str(laptop_pubkey),
            "--agent-name", "agent one",
            "--subject", "Remote signer selection test case",
            "--message", "Text speech request.",
            env={"AGENT_NSEC": "nsec-agent-secret"},
            state=self.server_state,
        )
        output = json.loads(result.stdout)
        self.assertEqual(output["status"], "sent")

        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        request = events[-1]
        serialized = json.dumps(request, sort_keys=True)
        complete_transport = self.transport_file.read_text(encoding="utf-8")
        self.assertNotIn("nsec-agent-secret", serialized)
        backend = json.loads((self.server_state / "remote" / "backend.json").read_text())
        self.assertNotIn(backend["nsec"], serialized)
        self.assertNotIn("nsec-agent-secret", complete_transport)
        self.assertNotIn(backend["nsec"], complete_transport)
        self.assertEqual(request["kind"], 9)
        self.assertIn(["p", laptop_pubkey], request["tags"])
        self.assertIn(["h", "tts"], request["tags"])
        content = json.loads(request["content"])
        self.assertEqual(content["signer"]["source"], "AGENT_NSEC")
        self.assertEqual(request["pubkey"], backend_pubkey)
        self.assertNotIn("nsec", content["signer"])
        self.assertEqual(content["backend"]["pubkey"], backend_pubkey)
        self.assertEqual(content["request_id"], output["request_id"])
        inner = content["inner_event"]
        self.assertEqual(inner["kind"], 9)
        self.assertEqual(inner["pubkey"], content["signer"]["pubkey"])

    def test_daemon_materializes_text_request_through_existing_tts_queue(self) -> None:
        connected = self.pair()
        server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.run_tts(
                "remote", "speak",
                "--peer", str(connected["laptop_pubkey"]),
                "--agent-name", "remote agent",
                "--subject", "Remote text playback through queue",
                "--message", "Remote text works.",
                state=self.server_state,
            )
            result = self.run_tts(
                "daemon", "run", "--once", "--max-events", "1",
                env={
                    "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                    "TTS_REMOTE_DAEMON_NO_PLAY": "1",
                },
            )
            self.assertEqual(json.loads(result.stdout)["processed"], 1)
            items = list((self.laptop_state / "items").glob("*.json"))
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
        connected = self.pair()
        self.run_tts(
            "remote", "speak",
            "--peer", str(connected["laptop_pubkey"]),
            "--agent-name", "remote agent",
            "--subject", "Remote attachment safe failure",
            "--message", "Attachment should fail safely.",
            "--attach", "Missing file", "/not/on/this/laptop.txt",
            state=self.server_state,
        )
        result = self.run_tts("daemon", "run", "--once", "--max-events", "1")
        self.assertEqual(json.loads(result.stdout)["processed"], 1)
        self.assertFalse((self.laptop_state / "items").exists())

        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        reply = json.loads(events[-1]["content"])
        self.assertEqual(reply["status"], "rejected")
        self.assertEqual(reply["error"]["code"], "remote_attachment_unavailable")
        self.assertIn("send text only", reply["error"]["guidance"].lower())

    def test_daemon_lifecycle_status_uses_real_child_liveness(self) -> None:
        status = json.loads(self.run_tts("daemon", "status").stdout)
        self.assertEqual(status["running"], False)

        started = json.loads(self.run_tts("daemon", "start").stdout)
        self.assertEqual(started["status"], "started")
        for _ in range(20):
            status = json.loads(self.run_tts("daemon", "status").stdout)
            if status["running"]:
                break
            time.sleep(0.1)
        self.assertEqual(status["running"], True)
        self.assertIsInstance(status["state"]["pid"], int)

        stopped = json.loads(self.run_tts("daemon", "stop").stdout)
        self.assertEqual(stopped["status"], "stopped")
        self.assertEqual(json.loads(self.run_tts("daemon", "status").stdout)["running"], False)

    def test_cli_boundary_emits_structured_json_for_remote_transport_errors(self) -> None:
        result = self.run_tts(
            "daemon", "run", "--once", "--max-events", "1",
            env={"TTS_REMOTE_TRANSPORT": "unsupported"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        error = json.loads(result.stderr)
        self.assertEqual(error["status"], "error")
        self.assertEqual(error["error"]["code"], "remote_transport_error")
        self.assertNotIn("Traceback", result.stderr)

    def test_daemon_accepts_request_fetched_through_bounded_fake_nak_poll(self) -> None:
        connected = self.pair()
        server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        nak = self.state / "nak"
        nak.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "store = pathlib.Path(os.environ['TTS_REMOTE_TRANSPORT_FILE'])\n"
            "if sys.argv[1] == 'req':\n"
            "    print(store.read_text() if store.exists() else '')\n"
            "elif sys.argv[1] == 'event':\n"
            "    with store.open('a') as handle: handle.write(sys.stdin.read().strip() + '\\n')\n"
            "else:\n"
            "    sys.exit(2)\n",
            encoding="utf-8",
        )
        nak.chmod(0o700)
        self.run_tts(
            "remote", "speak",
            "--peer", str(connected["laptop_pubkey"]),
            "--agent-name", "remote agent",
            "--subject", "Fake nak request",
            "--message", "Fetched through fake nak.",
            state=self.server_state,
            env={"TTS_REMOTE_TRANSPORT": "file"},
        )
        try:
            result = self.run_tts(
                "daemon", "run", "--once", "--max-events", "1",
                env={
                    "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                    "TTS_REMOTE_TRANSPORT": "nak",
                    "TTS_NAK_BIN": str(nak),
                    "TTS_FAKE_NOSTR": "1",
                    "TTS_REMOTE_DAEMON_NO_PLAY": "1",
                },
            )
            self.assertEqual(json.loads(result.stdout)["processed"], 1)
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Contracts for remote TTS request and daemon commands."""

from __future__ import annotations

from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_pair_token import decode_pair_token
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
        self.base_environment["TTS_REMOTE_NO_MENU"] = "1"
        self.base_environment["TTS_GROUP_CONFIRM_TIMEOUT_SECONDS"] = "3"

    def tearDown(self) -> None:
        self.run_tts("daemon", "stop", check=False)
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
        code = decode_pair_token(offer["pair_code"])
        self.run_tts("daemon", "start")
        connected = json.loads(self.run_tts("pair", "connect", "--code", offer["pair_code"], state=self.server_state).stdout)
        self.run_tts("daemon", "stop")
        connected["peer_pubkey"] = code["peer"]
        connected["channel"] = code["channel"]
        return connected

    def test_remote_request_never_serializes_signer_secret_and_keeps_stable_backend_reply_endpoint(self) -> None:
        connected = self.pair()
        backend_pubkey = connected["backend_pubkey"]
        peer_pubkey = connected["peer_pubkey"]
        result = self.run_tts(
            "remote", "speak",
            "--peer", str(peer_pubkey),
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
        membership = events[-2]
        serialized = json.dumps(request, sort_keys=True)
        complete_transport = self.transport_file.read_text(encoding="utf-8")
        self.assertNotIn("nsec-agent-secret", serialized)
        backend = json.loads((self.server_state / "remote" / "backend.json").read_text())
        self.assertNotIn(backend["nsec"], serialized)
        self.assertNotIn("nsec-agent-secret", complete_transport)
        self.assertNotIn(backend["nsec"], complete_transport)
        self.assertEqual(request["kind"], 9)
        self.assertIn(["p", peer_pubkey], request["tags"])
        self.assertIn(["h", "tts"], request["tags"])
        content = json.loads(request["content"])
        self.assertEqual(request["pubkey"], output["author_pubkey"])
        self.assertNotEqual(request["pubkey"], backend_pubkey)
        self.assertEqual(content["backend"]["pubkey"], backend_pubkey)
        self.assertEqual(content["request_id"], output["request_id"])
        self.assertNotIn("inner_event", content)
        self.assertNotIn("signer", content)
        self.assertEqual(membership["kind"], 9000)
        self.assertIn(["p", request["pubkey"]], membership["tags"])
        self.assertEqual(membership["pubkey"], backend_pubkey)

    def test_daemon_materializes_text_request_through_existing_tts_queue(self) -> None:
        connected = self.pair()
        server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.run_tts(
                "remote", "speak",
                "--peer", str(connected["peer_pubkey"]),
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
            self.assertIn(["p", connected["backend_pubkey"]], reply["tags"])
            self.assertEqual(json.loads(reply["content"])["status"], "accepted")
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_daemon_rejects_inaccessible_remote_attachments_with_structured_guidance(self) -> None:
        connected = self.pair()
        self.run_tts(
            "remote", "speak",
            "--peer", str(connected["peer_pubkey"]),
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

    def test_daemon_passes_laptop_accessible_attachments_to_local_queue(self) -> None:
        connected = self.pair()
        attachment = self.state / "shared-notes.md"
        attachment.write_text("# Remote notes\n\nVerified on the laptop.\n", encoding="utf-8")
        server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.run_tts(
                "remote", "speak",
                "--peer", str(connected["peer_pubkey"]),
                "--agent-name", "remote agent",
                "--subject", "Remote accessible attachment delivery test",
                "--message", "The attachment should appear locally.",
                "--attach", "Remote notes", str(attachment),
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
            item = json.loads(next((self.laptop_state / "items").glob("*.json")).read_text())
            self.assertEqual(item["attachments"][0]["label"], "Remote notes")
            self.assertTrue(Path(item["attachments"][0]["source_file"]).is_file())
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

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
            "--peer", str(connected["peer_pubkey"]),
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
            cursor = json.loads((self.laptop_state / "remote" / "relay-cursors.json").read_text())
            self.assertGreater(cursor["wss://nip29.f7z.io|requests"], 0)
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()


if __name__ == "__main__":
    unittest.main()

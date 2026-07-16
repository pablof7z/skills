#!/usr/bin/env python3
"""Contracts for remote TTS pairing commands."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class RemotePairingCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-pair-")
        self.state = Path(self.temporary.name)
        (self.state / "home").mkdir()
        repository = Path(__file__).resolve().parents[2]
        self.tts = repository / "tts" / "scripts" / "tts"
        self.transport_file = self.state / "transport.jsonl"
        self.environment = os.environ.copy()
        self.environment["HOME"] = str(self.state / "home")
        self.environment["TTS_STATE_DIR"] = str(self.state)
        self.environment["TTS_REMOTE_TRANSPORT"] = "file"
        self.environment["TTS_REMOTE_TRANSPORT_FILE"] = str(self.transport_file)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_tts(self, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.tts), *arguments],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_pair_offer_emits_agent_facing_code_without_protocol_jargon(self) -> None:
        result = self.run_tts(
            "pair", "offer",
            "--relay", "wss://relay.example.test",
            "--laptop-pubkey", "laptop-pubkey",
            "--ttl", "60",
        )
        output = json.loads(result.stdout)
        code = output["pair_code"]
        self.assertEqual(code["version"], 1)
        self.assertEqual(code["product"], "tts")
        self.assertEqual(code["relay"], "wss://relay.example.test")
        self.assertEqual(code["laptop_pubkey"], "laptop-pubkey")
        self.assertRegex(code["pairing_id"], r"^[a-f0-9]{32}$")
        self.assertRegex(code["secret"], r"^[A-Za-z0-9_-]{32,}$")
        self.assertNotIn("hmac", json.dumps(code).lower())
        self.assertNotIn("encrypted", json.dumps(code).lower())
        guidance = " ".join(output["next_steps"]).lower()
        self.assertNotIn("nostr", guidance)
        self.assertNotIn("nip", guidance)

    def test_pair_connect_publishes_raw_secret_and_approves_backend_peer(self) -> None:
        offer = json.loads(
            self.run_tts(
                "pair", "offer",
                "--relay", "wss://relay.example.test",
                "--laptop-pubkey", "laptop-pubkey",
            ).stdout
        )
        result = self.run_tts("pair", "connect", "--code", json.dumps(offer["pair_code"]))
        connected = json.loads(result.stdout)
        self.assertEqual(connected["status"], "connected")
        self.assertEqual(connected["peer"]["product"], "tts")
        self.assertEqual(connected["peer"]["approved"], True)

        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        pairing_event = events[-1]
        self.assertEqual(pairing_event["kind"], 24)
        self.assertEqual(pairing_event["content"], offer["pair_code"]["secret"])
        self.assertIn(["p", "laptop-pubkey"], pairing_event["tags"])
        self.assertIn(["pairing", offer["pair_code"]["pairing_id"]], pairing_event["tags"])

        backend = json.loads((self.state / "remote" / "backend.json").read_text())
        self.assertTrue(backend["nsec"].startswith("nsec"))
        self.assertEqual(backend["product"], "tts")
        self.assertEqual(backend["approved"], True)

        reused = self.run_tts("pair", "connect", "--code", json.dumps(offer["pair_code"]), check=False)
        self.assertNotEqual(reused.returncode, 0)
        self.assertEqual(json.loads(reused.stderr)["error"]["code"], "pair_code_used")

    def test_pair_list_status_and_revoke_are_structured(self) -> None:
        offer = json.loads(
            self.run_tts(
                "pair", "offer",
                "--relay", "wss://relay.example.test",
                "--laptop-pubkey", "laptop-pubkey",
            ).stdout
        )
        self.run_tts("pair", "connect", "--code", json.dumps(offer["pair_code"]))

        listed = json.loads(self.run_tts("pair", "list").stdout)
        self.assertEqual(len(listed["peers"]), 1)
        peer_id = listed["peers"][0]["id"]
        self.assertEqual(json.loads(self.run_tts("pair", "status").stdout)["paired"], True)

        revoked = json.loads(self.run_tts("pair", "revoke", peer_id).stdout)
        self.assertEqual(revoked["status"], "revoked")
        self.assertEqual(json.loads(self.run_tts("pair", "status").stdout)["paired"], False)


if __name__ == "__main__":
    unittest.main()

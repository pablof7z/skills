#!/usr/bin/env python3
"""Contracts for remote TTS pairing commands."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import stat
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_pair_token import PAIRING_KIND, decode_pair_token


class RemotePairingCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-pair-")
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
        self.base_environment["TTS_GROUP_CONFIRM_TIMEOUT_SECONDS"] = "3"
        self.base_environment["TTS_REMOTE_NO_MENU"] = "1"

    def tearDown(self) -> None:
        self.run_tts("daemon", "stop", check=False)
        self.temporary.cleanup()

    def env_for(self, state: Path) -> dict[str, str]:
        environment = self.base_environment.copy()
        environment["HOME"] = str(state / "home")
        environment["TTS_STATE_DIR"] = str(state)
        return environment

    def run_tts(self, *arguments: str, state: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.tts), *arguments],
            env=self.env_for(state or self.laptop_state),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_pair_offer_emits_agent_facing_code_without_protocol_jargon(self) -> None:
        result = self.run_tts(
            "pair", "offer",
            "--relay", "wss://relay.example.test",
            "--channel", "wss://nip29.example/spoken-updates",
        )
        output = json.loads(result.stdout)
        token = output["pair_code"]
        self.assertIsInstance(token, str)
        self.assertLess(len(token), 220)
        code = decode_pair_token(token)
        self.assertEqual(set(code), {"peer", "secret", "relay", "channel"})
        self.assertEqual(code["relay"], "wss://relay.example.test")
        self.assertEqual(code["channel"], "wss://nip29.example/spoken-updates")
        self.assertRegex(code["peer"], r"^[a-f0-9]{64}$")
        self.assertRegex(code["secret"], r"^[A-Za-z0-9_-]{32,}$")
        laptop = json.loads((self.laptop_state / "remote" / "laptop.json").read_text())
        self.assertEqual(laptop["pubkey"], code["peer"])
        self.assertIsNotNone(laptop["nsec"])
        self.assertNotIn("hmac", json.dumps(code).lower())
        self.assertNotIn("encrypted", json.dumps(code).lower())
        guidance = " ".join(output["next_steps"]).lower()
        self.assertNotIn("nostr", guidance)
        self.assertNotIn("nip", guidance)

    def test_pair_connect_waits_until_laptop_confirms_backend_admin(self) -> None:
        offer = json.loads(
            self.run_tts(
                "pair", "offer",
                "--relay", "wss://relay.example.test",
            ).stdout
        )
        code = decode_pair_token(offer["pair_code"])
        peer_pubkey = code["peer"]
        self.run_tts("daemon", "start")
        result = self.run_tts("pair", "connect", "--code", offer["pair_code"], state=self.server_state)
        self.run_tts("daemon", "stop")
        connected = json.loads(result.stdout)
        self.assertEqual(connected["status"], "connected")
        self.assertEqual(connected["peer"]["product"], "tts")
        self.assertEqual(connected["peer"]["approved"], True)

        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        pairing_event = next(event for event in events if event["kind"] == PAIRING_KIND)
        self.assertEqual(pairing_event["kind"], PAIRING_KIND)
        self.assertEqual(pairing_event["content"], code["secret"])
        self.assertEqual(pairing_event["tags"], [["p", peer_pubkey]])
        self.assertEqual(events[0]["kind"], 9007)
        self.assertIn(["h", "tts"], events[0]["tags"])

        backend = json.loads((self.server_state / "remote" / "backend.json").read_text())
        self.assertTrue(backend["nsec"].startswith("nsec"))
        self.assertEqual(backend["product"], "tts")
        self.assertEqual(backend["approved"], True)
        self.assertEqual(stat.S_IMODE((self.server_state / "remote").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.server_state / "remote" / "backend.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.laptop_state / "remote" / "laptop.json").stat().st_mode), 0o600)

        laptop_peers = json.loads((self.laptop_state / "remote" / "peers.json").read_text())
        self.assertEqual(laptop_peers[0]["pubkey"], connected["backend_pubkey"])
        self.assertEqual(laptop_peers[0]["approved"], True)
        self.assertEqual(laptop_peers[0]["channel"], code["channel"])
        membership_events = [event for event in events if event["kind"] == 9000]
        self.assertEqual([event["kind"] for event in membership_events], [9000, 9000])
        self.assertIn(["p", connected["backend_pubkey"]], membership_events[0]["tags"])
        self.assertIn(["p", connected["backend_pubkey"], "admin"], membership_events[1]["tags"])

        replay = json.loads(self.run_tts("daemon", "run", "--once", "--max-events", "1").stdout)
        self.assertEqual(replay["processed"], 0)
        laptop_peers_after_replay = json.loads((self.laptop_state / "remote" / "peers.json").read_text())
        self.assertEqual(laptop_peers_after_replay, laptop_peers)

        reused = self.run_tts("pair", "connect", "--code", offer["pair_code"], state=self.server_state, check=False)
        self.assertNotEqual(reused.returncode, 0)
        self.assertEqual(json.loads(reused.stderr)["error"]["code"], "pair_code_used")

    def test_laptop_daemon_rejects_wrong_secret_and_wrong_recipient(self) -> None:
        offer = json.loads(self.run_tts("pair", "offer", "--relay", "file://transport").stdout)
        code = decode_pair_token(offer["pair_code"])
        failed = self.run_tts(
            "pair", "connect", "--code", offer["pair_code"],
            state=self.server_state,
            check=False,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse((self.server_state / "remote" / "peers.json").exists())
        self.assertFalse((self.server_state / "remote" / "used-pairings.json").exists())
        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        valid = events[-1]
        variants = []
        for content, tags in (("wrong-secret", valid["tags"]), (code["secret"], [["p", "0" * 64]])):
            changed = dict(valid)
            changed["id"] = changed["id"] + content[:1]
            changed["content"] = content
            changed["tags"] = tags
            variants.append(changed)
        self.transport_file.write_text("\n".join(json.dumps(event) for event in variants) + "\n")

        result = json.loads(self.run_tts("daemon", "run", "--once", "--max-events", "10").stdout)
        self.assertEqual(result["processed"], 0)
        self.assertFalse((self.laptop_state / "remote" / "peers.json").exists())
        seen = json.loads((self.laptop_state / "remote" / "daemon-seen.json").read_text())
        self.assertEqual(set(seen), {variants[0]["id"]})

    def test_pair_list_status_and_revoke_are_structured(self) -> None:
        offer = json.loads(
            self.run_tts(
                "pair", "offer",
                "--relay", "wss://relay.example.test",
            ).stdout
        )
        self.run_tts("daemon", "start")
        self.run_tts("pair", "connect", "--code", offer["pair_code"], state=self.server_state)
        self.run_tts("daemon", "stop")

        listed = json.loads(self.run_tts("pair", "list", state=self.server_state).stdout)
        self.assertEqual(len(listed["peers"]), 1)
        peer_id = listed["peers"][0]["id"]
        self.assertEqual(json.loads(self.run_tts("pair", "status", state=self.server_state).stdout)["paired"], True)

        revoked = json.loads(self.run_tts("pair", "revoke", peer_id, state=self.server_state).stdout)
        self.assertEqual(revoked["status"], "revoked")
        self.assertEqual(json.loads(self.run_tts("pair", "status", state=self.server_state).stdout)["paired"], False)


if __name__ == "__main__":
    unittest.main()

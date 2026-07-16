#!/usr/bin/env python3
"""Contracts for remote TTS pairing commands."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import stat
import tempfile
import unittest


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

    def tearDown(self) -> None:
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

    def test_pair_connect_publishes_raw_secret_without_approving_laptop_until_daemon_validates(self) -> None:
        offer = json.loads(
            self.run_tts(
                "pair", "offer",
                "--relay", "wss://relay.example.test",
            ).stdout
        )
        laptop_pubkey = offer["pair_code"]["laptop_pubkey"]
        result = self.run_tts("pair", "connect", "--code", json.dumps(offer["pair_code"]), state=self.server_state)
        connected = json.loads(result.stdout)
        self.assertEqual(connected["status"], "connected")
        self.assertEqual(connected["peer"]["product"], "tts")
        self.assertEqual(connected["peer"]["approved"], True)

        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        pairing_event = events[-1]
        self.assertEqual(pairing_event["kind"], 24)
        self.assertEqual(pairing_event["content"], offer["pair_code"]["secret"])
        self.assertIn(["p", laptop_pubkey], pairing_event["tags"])
        self.assertIn(["pairing", offer["pair_code"]["pairing_id"]], pairing_event["tags"])

        backend = json.loads((self.server_state / "remote" / "backend.json").read_text())
        self.assertTrue(backend["nsec"].startswith("nsec"))
        self.assertEqual(backend["product"], "tts")
        self.assertEqual(backend["approved"], True)
        self.assertEqual(stat.S_IMODE((self.server_state / "remote").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.server_state / "remote" / "backend.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.laptop_state / "remote" / "laptop.json").stat().st_mode), 0o600)

        self.assertFalse((self.laptop_state / "remote" / "peers.json").exists())
        accepted = json.loads(self.run_tts("daemon", "run", "--once", "--max-events", "1").stdout)
        self.assertEqual(accepted["processed"], 1)
        laptop_peers = json.loads((self.laptop_state / "remote" / "peers.json").read_text())
        self.assertEqual(laptop_peers[0]["pubkey"], connected["backend_pubkey"])
        self.assertEqual(laptop_peers[0]["approved"], True)

        replay = json.loads(self.run_tts("daemon", "run", "--once", "--max-events", "1").stdout)
        self.assertEqual(replay["processed"], 0)
        laptop_peers_after_replay = json.loads((self.laptop_state / "remote" / "peers.json").read_text())
        self.assertEqual(laptop_peers_after_replay, laptop_peers)

        reused = self.run_tts("pair", "connect", "--code", json.dumps(offer["pair_code"]), state=self.server_state, check=False)
        self.assertNotEqual(reused.returncode, 0)
        self.assertEqual(json.loads(reused.stderr)["error"]["code"], "pair_code_used")

    def test_laptop_daemon_rejects_wrong_secret_wrong_product_expired_and_unpaired_attacker(self) -> None:
        offer = json.loads(self.run_tts("pair", "offer", "--relay", "file://transport", "--ttl", "60").stdout)
        code = offer["pair_code"]
        self.run_tts("pair", "connect", "--code", json.dumps(code), state=self.server_state)
        events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
        valid = events[-1]
        offer_path = self.laptop_state / "remote" / "pairings" / f"{code['pairing_id']}.json"
        expired_offer = json.loads(offer_path.read_text())
        expired_offer["code"]["expires_at"] = 1
        offer_path.write_text(json.dumps(expired_offer), encoding="utf-8")
        variants = [valid]
        for content, tags in (
            ("wrong-secret", valid["tags"]),
            (code["secret"], [["p", code["laptop_pubkey"]], ["pairing", code["pairing_id"]], ["product", "other"]]),
            (code["secret"], [["p", code["laptop_pubkey"]], ["pairing", "missing-offer"], ["product", "tts"]]),
        ):
            changed = dict(valid)
            changed["id"] = changed["id"] + content[:1]
            changed["content"] = content
            changed["tags"] = tags
            variants.append(changed)
        attacker = dict(valid)
        attacker["id"] = "attacker-event"
        attacker["pubkey"] = "attacker-pubkey"
        variants.append(attacker)
        self.transport_file.write_text("\n".join(json.dumps(event) for event in variants) + "\n")

        result = json.loads(self.run_tts("daemon", "run", "--once", "--max-events", "10").stdout)
        self.assertEqual(result["processed"], 0)
        self.assertFalse((self.laptop_state / "remote" / "peers.json").exists())

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

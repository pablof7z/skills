#!/usr/bin/env python3
"""Contract tests for reusable human-endpoint pairing and transport."""

from __future__ import annotations

import json
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from human_endpoint_protocol.runtime import (
    BackendEndpoint,
    LaptopEndpoint,
    PairingCode,
    RemoteHumanError,
)
from human_endpoint_protocol.transport import FakeRelayTransport, NakTransport


class HumanEndpointProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="human-endpoint-")
        self.root = Path(self.temporary.name)
        self.transport = FakeRelayTransport()
        self.now = 1_800_000_000
        self.laptop = LaptopEndpoint(
            product="tts",
            relay_url="ws://relay.test",
            pubkey="laptop-pub",
            state_path=self.root / "laptop.json",
            now=lambda: self.now,
        )
        self.backend = BackendEndpoint(
            product="tts",
            hostname="ci-host",
            state_path=self.root / "backend.json",
            transport=self.transport,
            now=lambda: self.now,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def pair(self) -> PairingCode:
        code = self.laptop.create_pairing_code(
            pairing_id="pair-1",
            secret="secret-1",
            expires_in=60,
        )
        self.backend.publish_pairing_request(code)
        request = self.transport.events(kind=30390)[0]
        self.laptop.consume_pairing_request(request)
        return code

    def test_pairing_persists_backend_identity_and_group_configuration(self) -> None:
        code = self.pair()
        backend_state = json.loads((self.root / "backend.json").read_text())
        identity = backend_state["backend"]["products"]["tts"]
        self.assertEqual(identity["nsec"], self.backend.nsec)
        self.assertEqual(identity["pubkey"], self.backend.pubkey)
        state = json.loads((self.root / "laptop.json").read_text())
        backend = state["approved_backends"][self.backend.pubkey]
        self.assertEqual(backend["product"], "tts")
        self.assertEqual(backend["relay_url"], code.relay_url)
        self.assertEqual(backend["group"]["id"], "tts:pair-1")
        metadata = self.transport.events(kind=0)[0]
        self.assertEqual(metadata["pubkey"], self.backend.pubkey)
        self.assertIn("ci-host tts daemon", metadata["content"])

    def test_pairing_rejects_expired_wrong_product_wrong_secret_and_replay(self) -> None:
        expired = self.laptop.create_pairing_code("expired", "old", expires_in=-1)
        with self.assertRaisesRegex(RemoteHumanError, "pairing_expired"):
            self.backend.publish_pairing_request(expired)

        code = self.laptop.create_pairing_code("pair-2", "secret-2", expires_in=60)
        wrong_product = PairingCode.from_json(code.to_json())
        wrong_product.product = "worktree-guard"
        with self.assertRaisesRegex(RemoteHumanError, "product_mismatch"):
            self.backend.publish_pairing_request(wrong_product)

        self.backend.publish_pairing_request(code)
        request = self.transport.events(kind=30390)[-1]
        request["content"] = json.dumps({**json.loads(request["content"]), "secret": "bad"})
        with self.assertRaisesRegex(RemoteHumanError, "secret_mismatch"):
            self.laptop.consume_pairing_request(request)

        self.backend.publish_pairing_request(code)
        request = self.transport.events(kind=30390)[-1]
        self.laptop.consume_pairing_request(request)
        with self.assertRaisesRegex(RemoteHumanError, "pairing_replayed"):
            self.laptop.consume_pairing_request(request)

    def test_messages_are_correlated_idempotent_and_revocable(self) -> None:
        self.pair()
        request = self.backend.send_request("Approve?", request_id="req-1")
        duplicate = dict(request)
        self.laptop.receive_request(request)
        self.laptop.receive_request(duplicate)
        self.laptop.reply(request, "Approved")
        self.laptop.reply(request, "Approved")
        replies = self.backend.collect_replies("req-1", timeout_seconds=0.1)
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]["content"], "Approved")
        self.assertEqual(replies[0]["tags"], [["e", request["id"]], ["p", self.backend.pubkey]])

        self.laptop.revoke_backend(self.backend.pubkey)
        with self.assertRaisesRegex(RemoteHumanError, "backend_revoked"):
            self.laptop.receive_request(self.backend.send_request("Again?", request_id="req-2"))

    def test_collect_replies_times_out_with_structured_json_error(self) -> None:
        self.pair()
        self.backend.send_request("Need input", request_id="req-timeout")
        with self.assertRaises(RemoteHumanError) as raised:
            self.backend.collect_replies("req-timeout", timeout_seconds=0.01)
        self.assertEqual(json.loads(raised.exception.to_json())["code"], "timeout")

    def test_nak_transport_reports_missing_dependency_as_json(self) -> None:
        transport = NakTransport(nak_path="/definitely/missing/nak")
        with self.assertRaises(RemoteHumanError) as raised:
            transport.publish({"kind": 9, "content": "hello", "tags": []})
        payload = json.loads(raised.exception.to_json())
        self.assertEqual(payload["code"], "missing_dependency")
        self.assertIn("nak", payload["message"])

    def test_executable_vectors_match_runtime_contract(self) -> None:
        repository = Path(__file__).resolve().parents[1]
        result = subprocess.run(
            [str(repository / "scripts" / "human-endpoint"), "vectors"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        vector = json.loads(result.stdout)["pairing_code_v1"]
        code = PairingCode.from_json(json.dumps(vector))
        self.assertEqual(code.version, 1)
        self.assertEqual(code.product, "tts")


if __name__ == "__main__":
    unittest.main()

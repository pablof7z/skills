#!/usr/bin/env python3
"""Contract tests for reusable human-endpoint pairing and transport."""

from __future__ import annotations

import json
import os
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
        code = self.pair()
        request = self.backend.send_request("Approve?", request_id="req-1")
        self.assertIn(["p", self.laptop.pubkey], request["tags"])
        self.assertIn(["h", f"{code.product}:{code.pairing_id}"], request["tags"])
        duplicate = dict(request)
        self.laptop.receive_request(request)
        self.laptop.receive_request(duplicate)
        self.laptop.reply(request, "Approved")
        self.laptop.reply(request, "Approved")
        replies = self.backend.collect_replies("req-1", timeout_seconds=0.1)
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]["content"], "Approved")
        self.assertEqual(
            replies[0]["tags"],
            [["e", request["id"]], ["p", self.backend.pubkey], ["h", f"{code.product}:{code.pairing_id}"]],
        )

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

    def test_nak_transport_uses_env_secret_and_queries_with_bounded_filters(self) -> None:
        nak = self.root / "fake-nak"
        log_path = self.root / "nak-calls.jsonl"
        event = {
            "id": "reply-event",
            "kind": 9,
            "pubkey": "laptop-pub",
            "content": "Approved",
            "tags": [["e", "request-event"], ["p", "backend-pub"], ["h", "tts:pair-1"]],
            "created_at": self.now,
            "sig": "sig",
        }
        nak.write_text(
            "\n".join(
                [
                    "#!/usr/bin/env python3",
                    "import json, os, sys",
                    f"log_path = {str(log_path)!r}",
                    "with open(log_path, 'a', encoding='utf-8') as handle:",
                    "    handle.write(json.dumps({'argv': sys.argv[1:], 'nsec': os.environ.get('NOSTR_SECRET_KEY')}) + '\\n')",
                    "if sys.argv[1] == 'event':",
                    "    print(json.dumps({'id': 'published-event', 'kind': 9, 'pubkey': 'backend-pub', 'tags': []}))",
                    "elif sys.argv[1] == 'req':",
                    f"    print({json.dumps(event)!r})",
                    "else:",
                    "    sys.exit(2)",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        nak.chmod(0o700)

        transport = NakTransport(relay_url="ws://relay.test", nsec="nsec-secret", nak_path=str(nak))
        transport.publish({"kind": 9, "content": "hello", "tags": []})
        events = transport.query({"kind": 9, "authors": ["laptop-pub"], "#e": "request-event", "limit": 2})

        self.assertEqual(events, [event])
        calls = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
        publish_call, query_call = calls
        self.assertEqual(publish_call["nsec"], "nsec-secret")
        self.assertNotIn("nsec-secret", publish_call["argv"])
        self.assertNotIn("--sec", publish_call["argv"])
        self.assertIn("--limit", query_call["argv"])
        self.assertIn("2", query_call["argv"])
        self.assertIn("--kind", query_call["argv"])
        self.assertIn("--author", query_call["argv"])
        self.assertNotIn("--no-verify", query_call["argv"])

    def test_nak_query_rejects_invalid_raw_event_with_structured_error(self) -> None:
        nak = self.root / "bad-nak"
        nak.write_text("#!/bin/sh\nprintf '%s\\n' '{\"kind\":9}'\n", encoding="utf-8")
        nak.chmod(0o700)
        transport = NakTransport(relay_url="ws://relay.test", nak_path=str(nak))
        with self.assertRaises(RemoteHumanError) as raised:
            transport.query({"kind": 9})
        payload = json.loads(raised.exception.to_json())
        self.assertEqual(payload["code"], "transport_invalid_event")

    def test_state_writes_are_atomic_private_files(self) -> None:
        self.pair()
        state_path = self.root / "laptop.json"
        self.assertEqual(os.stat(state_path.parent).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(state_path).st_mode & 0o777, 0o600)

    def test_kind9_rejects_wrong_target_group_and_reply_author(self) -> None:
        self.pair()
        request = self.backend.send_request("Approve?", request_id="req-validate")
        wrong_target = {**request, "id": "wrong-target", "tags": [["d", "req-validate"], ["p", "someone-else"], ["h", "tts:pair-1"]]}
        with self.assertRaisesRegex(RemoteHumanError, "target_mismatch"):
            self.laptop.receive_request(wrong_target)
        wrong_group = {**request, "id": "wrong-group", "tags": [["d", "req-validate"], ["p", "laptop-pub"], ["h", "other:pair"]]}
        with self.assertRaisesRegex(RemoteHumanError, "group_mismatch"):
            self.laptop.receive_request(wrong_group)

        reply = self.laptop.reply(request, "Approved")
        forged = {**reply, "id": "forged-reply", "pubkey": "not-laptop"}
        self.transport.publish(forged)
        with self.assertRaisesRegex(RemoteHumanError, "reply_author_mismatch"):
            self.backend.collect_replies("req-validate", timeout_seconds=0.1)

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
        self.assertEqual(code.relay_url, "ws://relay.test")
        self.assertIn("relay", vector)
        self.assertNotIn("relay_url", vector)

    def test_product_adapters_share_pairing_code_contract(self) -> None:
        repository = Path(__file__).resolve().parents[1]
        vector = json.loads((repository / "human_endpoint_protocol" / "test_vectors.json").read_text())["pairing_code_v1"]
        adapters = [
            (repository / "tts" / "scripts" / "tts-human-endpoint", {**vector, "product": "tts"}, "tts"),
            (
                repository / "plugins" / "worktree-guard" / "bin" / "wtg-human-endpoint",
                {**vector, "product": "worktree-guard", "pairing_id": "wtg-pair-1"},
                "worktree-guard",
            ),
        ]
        for adapter, product_vector, product in adapters:
            result = subprocess.run(
                [str(adapter), "validate-pairing-code", json.dumps(product_vector), "--product", product],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            self.assertEqual(json.loads(result.stdout)["pairing_id"], product_vector["pairing_id"])


if __name__ == "__main__":
    unittest.main()

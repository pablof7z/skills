from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard_lite.core import WorktreeGuardError
from worktreeguard_lite.remote_events import event_id, pubkey_for_secret, signed_event
from worktreeguard_lite.remote_pairing import derive_pubkey
from worktreeguard_lite.remote_approval import RemoteApprovalRequest, publish_request
from worktreeguard_lite.remote_transport import NakTransport


class WorktreeGuardNostrRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wtg-nostr-")
        self.root = Path(self.temporary.name)
        self.old_env = os.environ.copy()

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temporary.cleanup()

    def test_fake_transport_keeps_deterministic_fake_pubkeys_even_when_nak_exists(self) -> None:
        os.environ["WTG_TRANSPORT"] = "fake"
        os.environ["WTG_NAK_BIN"] = str(self.fake_nak(pubkey="d" * 64))

        self.assertEqual(derive_pubkey("secret"), pubkey_for_secret("secret"))

    def test_production_pubkey_uses_offline_signed_probe_when_env_key_public_is_empty(self) -> None:
        os.environ.pop("WTG_TRANSPORT", None)
        os.environ["WTG_NAK_BIN"] = str(self.fake_nak(pubkey="e" * 64))

        self.assertEqual(derive_pubkey("secret"), "e" * 64)

    def test_production_pubkey_fails_without_a_valid_nak_identity(self) -> None:
        os.environ.pop("WTG_TRANSPORT", None)
        os.environ["WTG_NAK_BIN"] = str(self.root / "missing-nak")

        with self.assertRaisesRegex(WorktreeGuardError, "requires `nak`"):
            derive_pubkey("secret")

    def test_publish_returns_the_event_id_actually_signed_by_nak(self) -> None:
        nak = self.fake_nak(pubkey="f" * 64)
        event = signed_event(kind=9, secret="placeholder", content={"message": "test"})

        published = NakTransport(str(nak)).publish("wss://relay.example", event)

        self.assertNotEqual(published["id"], event["id"])
        self.assertEqual(published["pubkey"], "f" * 64)

    def test_request_uses_the_id_returned_by_the_production_signer(self) -> None:
        class ChangedIdTransport:
            def publish(self, relay: str, event: dict[str, object]) -> dict[str, object]:
                return {**event, "id": "9" * 64}

        request = RemoteApprovalRequest("write", "/repo", "/repo", "#191", "session", 60)
        with patch(
            "worktreeguard_lite.remote_approval.transport",
            return_value=ChangedIdTransport(),
        ):
            request_id = publish_request(
                {"secret": "backend", "pubkey": "a" * 64},
                "wss://relay.example",
                "b" * 64,
                "wtg-group",
                request,
            )

        self.assertEqual(request_id, "9" * 64)

    def test_fetch_rejects_structurally_valid_event_with_forged_signature(self) -> None:
        forged = signed_event(kind=9, secret="forged", content={"message": "test"})
        forged.pop("_secret")
        forged["sig"] = "0" * 128
        self.assertEqual(forged["id"], event_id(forged))
        nak = self.fake_nak(pubkey="a" * 64, fetched_event=forged, reject_fetched_verify=True)

        events = NakTransport(str(nak)).fetch(
            "wss://relay.example",
            kinds={9},
            p_tag="b" * 64,
            h_tag="worktree-guard",
        )

        self.assertEqual(events, [])
        invocation = json.loads((self.root / "last-req.json").read_text(encoding="utf-8"))
        self.assertIn("-p", invocation)
        self.assertIn("-h", invocation)
        self.assertIn("b" * 64, invocation)
        self.assertIn("worktree-guard", invocation)

    def fake_nak(
        self,
        *,
        pubkey: str,
        fetched_event: dict[str, object] | None = None,
        reject_fetched_verify: bool = False,
    ) -> Path:
        nak = self.root / "fake-nak"
        probe = {
            "kind": 1,
            "pubkey": pubkey,
            "content": "",
            "tags": [],
            "created_at": 1,
            "sig": "4" * 128,
        }
        nak.write_text(
            "#!/usr/bin/env python3\n"
            "import hashlib, json, pathlib, sys\n"
            f"root = pathlib.Path({str(self.root)!r})\n"
            f"probe = {probe!r}\n"
            f"fetched = {fetched_event!r}\n"
            "def finish(event):\n"
            "    event = dict(event)\n"
            f"    event['pubkey'] = {pubkey!r}\n"
            "    payload = [0,event['pubkey'],event['created_at'],event['kind'],event.get('tags',[]),event.get('content','')]\n"
            "    event['id'] = hashlib.sha256(json.dumps(payload,separators=(',',':')).encode()).hexdigest()\n"
            "    event['sig'] = '4' * 128\n"
            "    return event\n"
            "probe = finish(probe)\n"
            "if sys.argv[1:3] == ['key', 'public']:\n"
            "    print('')\n"
            "elif sys.argv[1] == 'event':\n"
            "    incoming = sys.stdin.read().strip()\n"
            "    print(json.dumps(finish(json.loads(incoming))) if incoming else json.dumps(probe))\n"
            "elif sys.argv[1] == 'req':\n"
            "    (root / 'last-req.json').write_text(json.dumps(sys.argv))\n"
            "    if fetched is not None: print(json.dumps(fetched))\n"
            "elif sys.argv[1] == 'verify':\n"
            "    event = json.loads(sys.stdin.read())\n"
            f"    if {reject_fetched_verify!r} and fetched is not None and event.get('id') == fetched.get('id'): sys.exit(1)\n"
            "else:\n"
            "    sys.exit(2)\n",
            encoding="utf-8",
        )
        nak.chmod(0o700)
        return nak


if __name__ == "__main__":
    unittest.main()

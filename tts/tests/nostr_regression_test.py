#!/usr/bin/env python3
"""Remote TTS Nostr regressions for issue #191."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from subprocess import TimeoutExpired
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_remote_signing import fake_signed_event, public_key, verify_event
from tts_remote_state import ensure_backend, ensure_laptop_identity, public_key_for_secret
from tts_remote_transport import NakTransport


class TTSNostrRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-nostr-")
        self.root = Path(self.temporary.name)
        self.old_env = os.environ.copy()
        os.environ.clear()
        os.environ.update({"HOME": str(self.root / "home"), "TTS_STATE_DIR": str(self.root / "state")})

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temporary.cleanup()

    def fake_nak(self, *, pubkey: str = "b" * 64) -> Path:
        nak = self.root / "fake-nak"
        nak.write_text(
            "#!/usr/bin/env python3\n"
            "import json, sys, time\n"
            "if sys.argv[1:3] == ['key', 'generate']:\n"
            "    print('nsec-generated')\n"
            "elif sys.argv[1:3] == ['key', 'public']:\n"
            "    print('')\n"
            "elif sys.argv[1] == 'event':\n"
            f"    print(json.dumps({{'id':'e','kind':1,'pubkey':{pubkey!r},'content':'','tags':[],'created_at':1,'sig':'s'}}))\n"
            "elif sys.argv[1] == 'verify':\n"
            "    sys.exit(1)\n"
            "elif sys.argv[1] == 'req':\n"
            "    print(json.dumps({'id':'e','kind':9,'pubkey':'p','content':'','tags':[],'created_at':1,'sig':'s'}), flush=True)\n"
            "    time.sleep(10)\n"
            "else:\n"
            "    sys.exit(2)\n",
            encoding="utf-8",
        )
        nak.chmod(0o700)
        return nak

    def test_public_keys_and_persisted_identities_come_from_offline_signed_probe(self) -> None:
        os.environ["TTS_NAK_BIN"] = str(self.fake_nak(pubkey="c" * 64))

        self.assertEqual(public_key("nsec-secret"), "c" * 64)
        self.assertEqual(public_key_for_secret("nsec-secret"), "c" * 64)
        self.assertEqual(ensure_backend()["pubkey"], "c" * 64)
        laptop = ensure_laptop_identity()
        self.assertEqual(laptop["pubkey"], "c" * 64)
        self.assertIsNotNone(laptop["nsec"])

    def test_production_verify_rejects_attacker_fake_signature_without_nak_verify(self) -> None:
        os.environ["TTS_NAK_BIN"] = str(self.fake_nak())
        event = fake_signed_event(kind=9, content="{}", tags=[], nsec="attacker")

        self.assertFalse(verify_event(event))

    def test_nak_events_uses_bounded_filtered_request_and_returns_partial_timeout_output(self) -> None:
        os.environ["TTS_NAK_TIMEOUT_SECONDS"] = "0.1"
        event = {"id": "e", "kind": 9, "pubkey": "p", "content": "", "tags": [], "created_at": 1, "sig": "s"}

        with mock.patch(
            "tts_remote_transport.subprocess.run",
            side_effect=TimeoutExpired(["nak"], 0.1, output=json.dumps(event) + "\n"),
        ):
            events = NakTransport("ws://relay").events()

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["kind"], 9)

    def test_nak_events_requests_kinds_9_and_24_with_finite_limit(self) -> None:
        captured: list[str] = []

        def run(args: list[str], **kwargs: object) -> object:
            captured.extend(args)
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch("tts_remote_transport.subprocess.run", run):
            NakTransport("ws://relay").events()

        self.assertIn("req", captured)
        self.assertIn("--limit", captured)
        self.assertIn("200", captured)
        self.assertIn("9", captured)
        self.assertIn("24", captured)


if __name__ == "__main__":
    unittest.main()

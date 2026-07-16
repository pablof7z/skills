#!/usr/bin/env python3
"""Offline smoke tests for an installed real nak binary."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import unittest

from human_endpoint_protocol.transport import NakTransport


class RealNakSmokeTests(unittest.TestCase):
    def test_generated_key_derives_pubkey_and_verifies_offline_signed_event_without_relay(self) -> None:
        nak = shutil.which(os.environ.get("NAK_BIN", "nak"))
        if nak is None:
            self.skipTest("nak is not installed")
        secret = NakTransport(nak_path=nak).generate_secret_key()
        pubkey = NakTransport(nak_path=nak).public_key_for_secret(secret)
        self.assertRegex(pubkey, r"^[0-9a-f]{64}$")
        signed = subprocess.run(
            [nak, "event", "--kind", "1", "--content", "offline smoke"],
            env={**os.environ, "NOSTR_SECRET_KEY": secret},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=5,
        )
        self.assertNotIn(secret, " ".join([nak, "event", "--kind", "1", "--content", "offline smoke"]))
        event = self.parse_event(signed.stdout)
        self.assertEqual(event["pubkey"], pubkey)
        self.assertNotIn(secret, signed.stdout)
        verified = subprocess.run(
            [nak, "verify"],
            input=json.dumps(event),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=5,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def parse_event(self, raw: str) -> dict[str, object]:
        for line in reversed(raw.splitlines()):
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict) and re.fullmatch(r"[0-9a-f]{64}", str(event.get("pubkey") or "")):
                return event
        self.fail("nak did not emit a signed event")


if __name__ == "__main__":
    unittest.main()

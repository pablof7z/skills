from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from worktreeguard_lite.remote_events import pubkey_for_secret
from worktreeguard_lite.remote_pairing import derive_pubkey


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

    def fake_nak(self, *, pubkey: str) -> Path:
        nak = self.root / "fake-nak"
        nak.write_text(
            "#!/usr/bin/env python3\n"
            "import json, sys\n"
            "if sys.argv[1:3] == ['key', 'public']:\n"
            "    print('')\n"
            "elif sys.argv[1] == 'event':\n"
            f"    print(json.dumps({{'id':'e','kind':1,'pubkey':{pubkey!r},'content':'','tags':[],'created_at':1,'sig':'s'}}))\n"
            "else:\n"
            "    sys.exit(2)\n",
            encoding="utf-8",
        )
        nak.chmod(0o700)
        return nak


if __name__ == "__main__":
    unittest.main()

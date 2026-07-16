#!/usr/bin/env python3
"""Nostr transport regressions for issue #191."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from subprocess import TimeoutExpired
from unittest import mock

from human_endpoint_protocol.transport import NakTransport


class NostrTransportRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="nostr-transport-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_public_key_for_secret_uses_offline_signed_probe_when_env_key_public_is_empty(self) -> None:
        nak = self.root / "fake-nak"
        log_path = self.root / "calls.jsonl"
        expected = "a" * 64
        nak.write_text(
            "\n".join(
                [
                    "#!/usr/bin/env python3",
                    "import json, os, sys",
                    f"log_path = {str(log_path)!r}",
                    "with open(log_path, 'a', encoding='utf-8') as handle:",
                    "    handle.write(json.dumps({'argv': sys.argv[1:], 'nsec': os.environ.get('NOSTR_SECRET_KEY')}) + '\\n')",
                    "if sys.argv[1:3] == ['key', 'public']:",
                    "    print('')",
                    "elif sys.argv[1] == 'event':",
                    f"    print(json.dumps({{'id':'e','kind':1,'pubkey':{expected!r},'content':'','tags':[],'created_at':1,'sig':'s'}}))",
                    "else:",
                    "    sys.exit(2)",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        nak.chmod(0o700)

        pubkey = NakTransport(nak_path=str(nak)).public_key_for_secret("nsec-secret")

        self.assertEqual(pubkey, expected)
        calls = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(calls[-1]["nsec"], "nsec-secret")
        self.assertNotIn("nsec-secret", calls[-1]["argv"])

    def test_query_returns_partial_events_when_bounded_subprocess_times_out(self) -> None:
        event = {"id": "e", "kind": 9, "pubkey": "p", "content": "", "tags": [], "created_at": 1, "sig": "s"}
        with mock.patch("human_endpoint_protocol.transport.shutil.which", return_value="/bin/nak"):
            with mock.patch(
                "human_endpoint_protocol.transport.subprocess.run",
                side_effect=TimeoutExpired(["nak"], 0.1, output=json.dumps(event) + "\n"),
            ):
                events = NakTransport(relay_url="ws://relay", timeout_seconds=0.1).query({"kind": 9, "limit": 1})

        self.assertEqual(events, [event])


if __name__ == "__main__":
    unittest.main()

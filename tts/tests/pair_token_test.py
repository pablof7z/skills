#!/usr/bin/env python3
"""Compact TTS pair-token contracts for issue #196."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_pair_token import PairTokenError, decode_pair_token, encode_pair_token


class PairTokenTests(unittest.TestCase):
    def setUp(self) -> None:
        self.payload = {
            "peer": "a" * 64,
            "secret": "single-use-secret-0123456789",
            "relay": "wss://relay.primal.net",
            "channel": "wss://nip29.f7z.io/tts",
        }

    def test_round_trip_is_compact_opaque_and_exactly_four_fields(self) -> None:
        token = encode_pair_token(self.payload)

        self.assertTrue(token.startswith("ttspair1_"))
        self.assertNotIn("peer", token)
        self.assertNotIn("relay", token)
        self.assertLess(len(token), 220)
        self.assertEqual(decode_pair_token(token), self.payload)

    def test_encoder_rejects_extra_or_missing_fields(self) -> None:
        with self.assertRaises(PairTokenError):
            encode_pair_token({**self.payload, "version": 1})
        incomplete = dict(self.payload)
        incomplete.pop("channel")
        with self.assertRaises(PairTokenError):
            encode_pair_token(incomplete)

    def test_decoder_rejects_wrong_prefix_corruption_and_invalid_peer(self) -> None:
        for token in ("jwt.not.a.pair.code", "ttspair1_invalid!"):
            with self.assertRaises(PairTokenError):
                decode_pair_token(token)
        with self.assertRaises(PairTokenError):
            encode_pair_token({**self.payload, "peer": "not-a-pubkey"})


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Contracts for paired endpoint kind:0 hostname profiles."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_remote_profile import profile_name, publish_backend_profile, refresh_peer_profiles
from tts_remote_signing import fake_signed_event
from tts_remote_state import peers, save_peers
from tts_remote_transport import transport


class RemoteProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-profile-")
        self.root = Path(self.temporary.name)
        self.old_env = os.environ.copy()
        os.environ.clear()
        os.environ.update({
            "HOME": str(self.root / "home"),
            "TTS_STATE_DIR": str(self.root / "state"),
            "TTS_REMOTE_TRANSPORT": "file",
            "TTS_REMOTE_TRANSPORT_FILE": str(self.root / "transport.jsonl"),
            "TTS_FAKE_NOSTR": "1",
            "TTS_REMOTE_HOSTNAME": "kind2",
        })
        event = fake_signed_event(kind=0, content="", tags=[], nsec="server-secret")
        self.backend = {
            "nsec": "server-secret",
            "pubkey": event["pubkey"],
            "hostname": "kind2",
        }

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temporary.cleanup()

    def test_published_hostname_resolves_into_existing_peer_state(self) -> None:
        self.assertTrue(publish_backend_profile(self.backend, "file://pairing"))
        published = transport("file://pairing").events(
            author_pubkeys=[str(self.backend["pubkey"])],
            kinds=[0],
        )
        self.assertEqual(len(published), 1)
        self.assertEqual(json.loads(published[0]["content"])["name"], "kind2")

        save_peers([{
            "id": self.backend["pubkey"],
            "pubkey": self.backend["pubkey"],
            "relay": "file://pairing",
            "approved": True,
        }])
        self.assertEqual(refresh_peer_profiles(), 1)
        self.assertEqual(peers()[0]["name"], "kind2")
        self.assertEqual(profile_name(str(self.backend["pubkey"]), "file://pairing"), "kind2")

        self.assertTrue(publish_backend_profile(self.backend, "file://pairing"))
        self.assertEqual(len(transport("file://pairing").events(kinds=[0])), 1)

    def test_invalid_or_unavailable_profile_falls_back_without_breaking_pairing(self) -> None:
        forged = {
            "id": "forged",
            "pubkey": self.backend["pubkey"],
            "created_at": 1,
            "kind": 0,
            "tags": [],
            "content": '{"name":"attacker"}',
            "sig": "invalid",
        }
        transport("file://pairing").publish(forged)
        self.assertIsNone(profile_name(str(self.backend["pubkey"]), "file://pairing"))
        with mock.patch("tts_remote_profile.signed_event", side_effect=RuntimeError("offline")):
            self.assertFalse(publish_backend_profile(self.backend, "file://other"))


if __name__ == "__main__":
    unittest.main()

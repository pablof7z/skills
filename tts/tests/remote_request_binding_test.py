#!/usr/bin/env python3
"""Direct agent-authored remote TTS request binding regressions."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_remote_daemon import handle_request_event
from tts_remote_signing import fake_signed_event
from tts_remote_state import save_peers
from tts_remote_transport import transport


class RemoteRequestBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-binding-")
        self.root = Path(self.temporary.name)
        self.old_env = os.environ.copy()
        os.environ.clear()
        os.environ.update({
            "HOME": str(self.root / "home"),
            "TTS_STATE_DIR": str(self.root / "state"),
            "TTS_REMOTE_TRANSPORT": "file",
            "TTS_REMOTE_TRANSPORT_FILE": str(self.root / "transport.jsonl"),
            "TTS_FAKE_NOSTR": "1",
        })
        self.laptop = {"nsec": "laptop-secret", "pubkey": "laptop-pub"}
        self.server_nsec = "server-secret"
        self.server_pubkey = self.pubkey(self.server_nsec)
        self.agent_nsec = "agent-secret"
        self.agent_pubkey = self.pubkey(self.agent_nsec)
        save_peers([{
            "id": self.server_pubkey,
            "pubkey": self.server_pubkey,
            "approved": True,
            "relay": "file://relay",
            "channel": "tts",
        }])
        membership = fake_signed_event(
            kind=9000,
            content="",
            tags=[["h", "tts"], ["p", self.agent_pubkey]],
            nsec=self.server_nsec,
            relay="file://relay",
        )
        transport("file://relay").publish(membership)

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temporary.cleanup()

    def pubkey(self, nsec: str) -> str:
        return str(fake_signed_event(kind=9, content="{}", tags=[], nsec=nsec)["pubkey"])

    def request(
        self,
        *,
        nsec: str | None = None,
        content: str = "hello",
        tags: list[list[str]] | None = None,
    ) -> dict[str, object]:
        request_id = "req-1"
        event_tags = tags or [
            ["p", "laptop-pub"],
            ["h", "tts"],
            ["product", "tts"],
            ["request", request_id],
            ["reply", self.server_pubkey],
            ["subject", "subject"],
            ["agent", "agent"],
        ]
        return fake_signed_event(
            kind=9,
            content=content,
            tags=event_tags,
            nsec=nsec or self.agent_nsec,
            relay="file://relay",
        )

    def assert_rejected_before_materialization(self, event: dict[str, object]) -> None:
        with mock.patch(
            "tts_remote_daemon.materialize_request",
            side_effect=AssertionError("materialized forged request"),
        ):
            self.assertFalse(handle_request_event(event, self.laptop))

    def test_rejects_author_that_backend_has_not_admitted(self) -> None:
        self.assert_rejected_before_materialization(self.request(nsec="unadmitted-agent"))

    def test_rejects_wrong_reply_endpoint(self) -> None:
        wrong_reply = self.request(tags=[
            ["p", "laptop-pub"], ["h", "tts"], ["product", "tts"],
            ["request", "req-1"], ["reply", "wrong-backend"],
        ])

        self.assert_rejected_before_materialization(wrong_reply)

    def test_rejects_wrong_target_channel_or_request_tag(self) -> None:
        variants = [
            [["p", "other"], ["h", "tts"], ["product", "tts"], ["request", "req-1"], ["reply", self.server_pubkey]],
            [["p", "laptop-pub"], ["h", "other"], ["product", "tts"], ["request", "req-1"], ["reply", self.server_pubkey]],
            [["p", "laptop-pub"], ["h", "tts"], ["product", "tts"], ["reply", self.server_pubkey]],
        ]
        for tags in variants:
            self.assert_rejected_before_materialization(self.request(tags=tags))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Remote TTS inner/outer request binding regressions."""

from __future__ import annotations

import json
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


class RemoteRequestBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-binding-")
        self.root = Path(self.temporary.name)
        self.old_env = os.environ.copy()
        os.environ.clear()
        os.environ.update(
            {
                "HOME": str(self.root / "home"),
                "TTS_STATE_DIR": str(self.root / "state"),
                "TTS_REMOTE_TRANSPORT": "file",
                "TTS_REMOTE_TRANSPORT_FILE": str(self.root / "transport.jsonl"),
            }
        )
        self.backend = {"nsec": "laptop-secret", "pubkey": "laptop-pub"}
        self.server_nsec = "server-secret"
        self.server_pubkey = self.pubkey(self.server_nsec)
        self.agent_nsec = "agent-secret"
        self.agent_pubkey = self.pubkey(self.agent_nsec)
        save_peers([{"id": self.server_pubkey, "pubkey": self.server_pubkey, "approved": True, "relay": "file://relay"}])

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temporary.cleanup()

    def pubkey(self, nsec: str) -> str:
        return fake_signed_event(kind=9, content="{}", tags=[], nsec=nsec)["pubkey"]  # type: ignore[return-value]

    def request(
        self,
        *,
        inner_nsec: str | None = None,
        inner_updates: dict[str, object] | None = None,
        inner_tags: list[list[str]] | None = None,
    ) -> dict[str, object]:
        request_id = "req-1"
        inner_content = {
            "version": 1,
            "product": "tts",
            "request_id": request_id,
            "message": "hello",
            "subject": "subject",
            "agent_name": "agent",
            "attachments": [],
            "backend": {"pubkey": self.server_pubkey},
        }
        if inner_updates:
            inner_content.update(inner_updates)
        tags = inner_tags or [["p", "laptop-pub"], ["h", "tts"], ["product", "tts"], ["request", request_id], ["reply", self.server_pubkey]]
        inner = fake_signed_event(kind=9, content=json.dumps(inner_content, sort_keys=True), tags=tags, nsec=inner_nsec or self.agent_nsec)
        outer_content = {**inner_content, "inner_event": inner, "signer": {"source": "AGENT_NSEC", "pubkey": self.agent_pubkey}}
        return fake_signed_event(
            kind=9,
            content=json.dumps(outer_content, sort_keys=True),
            tags=[["p", "laptop-pub"], ["h", "tts"], ["product", "tts"], ["request", request_id], ["reply", self.server_pubkey]],
            nsec=self.server_nsec,
            relay="file://relay",
        )

    def assert_rejected_before_materialization(self, event: dict[str, object]) -> None:
        with mock.patch("tts_remote_daemon.materialize_request", side_effect=AssertionError("materialized forged request")):
            self.assertFalse(handle_request_event(event, self.backend))

    def test_rejects_inner_pubkey_that_does_not_match_declared_outer_signer(self) -> None:
        event = self.request(inner_nsec="other-agent-secret")

        self.assert_rejected_before_materialization(event)

    def test_rejects_inner_backend_and_reply_tags_not_bound_to_outer_author(self) -> None:
        wrong_backend = self.request(inner_updates={"backend": {"pubkey": "wrong-backend"}})
        wrong_reply = self.request(inner_tags=[["p", "laptop-pub"], ["h", "tts"], ["product", "tts"], ["request", "req-1"], ["reply", "wrong-backend"]])

        self.assert_rejected_before_materialization(wrong_backend)
        self.assert_rejected_before_materialization(wrong_reply)

    def test_rejects_inner_target_and_request_tags_that_differ_from_outer(self) -> None:
        wrong_target = self.request(inner_tags=[["p", "other-laptop"], ["h", "tts"], ["product", "tts"], ["request", "req-1"], ["reply", self.server_pubkey]])
        wrong_request = self.request(inner_tags=[["p", "laptop-pub"], ["h", "tts"], ["product", "tts"], ["request", "other-req"], ["reply", self.server_pubkey]])

        self.assert_rejected_before_materialization(wrong_target)
        self.assert_rejected_before_materialization(wrong_request)


if __name__ == "__main__":
    unittest.main()

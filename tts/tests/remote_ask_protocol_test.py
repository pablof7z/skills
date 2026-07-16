#!/usr/bin/env python3
"""Contracts for blocking remote TTS asks."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_remote_ask import prepare_ask, safe_response, wait_for_answer
from tts_remote_protocol import reply_tags, request_payload, request_tags
from tts_remote_signing import fake_signed_event
from tts_remote_transport import transport


class RemoteAskProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-ask-")
        self.old_env = os.environ.copy()
        os.environ.update({
            "HOME": self.temporary.name,
            "TTS_REMOTE_TRANSPORT": "file",
            "TTS_REMOTE_TRANSPORT_FILE": str(Path(self.temporary.name) / "transport.jsonl"),
            "TTS_FAKE_NOSTR": "1",
        })

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temporary.cleanup()

    def test_ask_stays_in_tags_and_round_trips_a_safe_answer(self) -> None:
        bundle = prepare_ask(json.dumps({
            "questions": [{
                "short_title": "Choice",
                "title": "Which option should the remote agent use?",
                "suggestions": [{"title": "First"}, {"title": "Second"}],
            }],
        }), "30s")
        tags = request_tags(
            peer_pubkey="laptop-pub",
            group_id="tts",
            backend_pubkey="backend-pub",
            request_id="request-1",
            subject="Choosing the next remote agent action",
            agent_name="remote-agent",
            attachments=[],
            ask=bundle,
            wait="30s",
        )
        request = fake_signed_event(
            kind=9,
            content="Please choose how I should continue.",
            tags=tags,
            nsec="agent-secret",
            relay="file://relay",
        )
        payload = request_payload(request)
        self.assertEqual(request["content"], "Please choose how I should continue.")
        self.assertEqual(payload["ask"], bundle)

        response = {"status": "answered", "questions": [{
            "id": "q-01",
            "status": "answered",
            "response": {"answer": "First, with edits.", "suggestion_ids": ["q-01-s-01"]},
        }]}
        reply = fake_signed_event(
            kind=9,
            content=request["content"],
            tags=reply_tags(request, "answered", response=response),
            nsec="laptop-secret",
            relay="file://relay",
        )
        request["pubkey"] = str(request["pubkey"])
        laptop_pubkey = str(reply["pubkey"])
        transport("file://relay").publish(reply)
        result = wait_for_answer(
            request_event=request,
            backend_pubkey="backend-pub",
            laptop_pubkey=laptop_pubkey,
            relay="file://relay",
            group_id="tts",
            wait="1s",
        )
        self.assertEqual(result["status"], "answered")
        self.assertEqual(result["response"]["questions"][0]["response"]["answer"], "First, with edits.")

    def test_safe_response_drops_laptop_attachment_paths(self) -> None:
        safe = safe_response({
            "status": "answered",
            "questions": [{
                "id": "q-01",
                "status": "answered",
                "response": {
                    "answer": "Proceed",
                    "attachments": [{"source_file": "/Users/private/answer.txt"}],
                },
            }],
            "answer_attachment_paths": ["/Users/private/answer.txt"],
        })
        self.assertNotIn("/Users/private", json.dumps(safe))

    def test_remote_ask_rejects_attachment_paths(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "paths are private"):
            prepare_ask(json.dumps({
                "questions": [{"short_title": "Choice", "title": "Pick", "attachments": ["/tmp/private"]}],
            }), "30s")

    def test_remote_ask_rejects_unbounded_wait(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "cannot exceed 1h"):
            prepare_ask(json.dumps({
                "questions": [{"short_title": "Choice", "title": "Pick"}],
            }), "2h")


if __name__ == "__main__":
    unittest.main()

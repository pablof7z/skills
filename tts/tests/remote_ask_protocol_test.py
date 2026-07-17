#!/usr/bin/env python3
"""Contracts for readable blocking remote TTS asks."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tts" / "scripts"))

from tts_remote_ask import answers_from_result, prepare_ask, wait_for_answer
from tts_remote_protocol import (
    render_reply_content,
    render_request_content,
    reply_tags,
    request_payload,
    request_tags,
)
from tts_remote_signing import fake_signed_event
from tts_remote_state import pubkey_for_nsec
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

    def ask(self) -> dict[str, object]:
        value = prepare_ask(json.dumps({
            "questions_preamble": "Settle the remaining deployment details.",
            "questions": [{
                "short_title": "Regions",
                "title": "Where should we deploy?",
                "description": "Select every applicable region.",
                "type": "multiple_choice",
                "suggestions": [
                    {"title": "Europe"},
                    {"title": "North America", "description": "Serve US and Canadian users."},
                ],
            }, {
                "short_title": "Timing",
                "title": "When should deployment begin?",
                "suggestions": [{"title": "Monday"}],
            }],
        }), "30s")
        assert value is not None
        return value

    def request(self) -> dict[str, object]:
        ask = self.ask()
        title = "Choose the deployment regions"
        summary = "The release is ready and needs a deployment decision."
        message = "The release is ready for a deployment decision."
        tags = request_tags(
            peer_pubkey=pubkey_for_nsec("laptop-secret"),
            group_id="tts",
            title=title,
            summary=summary,
            agent_name="remote-agent",
            message=message,
            attachments=[],
            ask=ask,
            wait="30s",
            session_id="v1/chat-a",
        )
        return fake_signed_event(
            kind=9,
            content=render_request_content(tags),
            tags=tags,
            nsec="agent-secret",
            relay="file://relay",
        )

    def test_questions_are_native_tags_with_readable_markdown(self) -> None:
        request = self.request()

        self.assertEqual(
            request["content"],
            "# Choose the deployment regions\n\n"
            "The release is ready for a deployment decision.\n\n"
            "Settle the remaining deployment details.\n\n"
            "1. **Where should we deploy?**\n"
            "   Select every applicable region.\n"
            "   - [ ] Europe\n"
            "   - [ ] North America — Serve US and Canadian users.\n\n"
            "2. **When should deployment begin?**\n"
            "   - [ ] Monday",
        )
        self.assertIn(["question", "q-01", "multiple", "Where should we deploy?"], request["tags"])
        self.assertIn(["option", "q-01", "Europe"], request["tags"])
        self.assertIn(["option", "q-01", "North America", "Serve US and Canadian users."], request["tags"])
        self.assertIn(
            ["summary", "The release is ready and needs a deployment decision."],
            request["tags"],
        )
        self.assertFalse({"ask", "product", "request", "reply", "response", "status"}.intersection(
            tag[0] for tag in request["tags"]
        ))

        payload = request_payload(request)
        self.assertIsNotNone(payload)
        self.assertEqual(payload["summary"], "The release is ready and needs a deployment decision.")
        self.assertEqual(payload["session_id"], "v1/chat-a")
        self.assertIn(["session", "v1/chat-a"], request["tags"])
        bundle = json.loads(str(payload["ask"]))
        self.assertEqual(bundle["questions"][0]["short_title"], "Regions")
        self.assertEqual(bundle["questions"][0]["type"], "multiple_choice")
        self.assertEqual(bundle["questions"][0]["suggestions"][1]["title"], "North America")

    def test_request_copy_is_normalized_and_rejects_titles_over_ten_words(self) -> None:
        tags = request_tags(
            peer_pubkey=pubkey_for_nsec("laptop-secret"),
            group_id="tts",
            title="MCP Audio",
            summary="Hosted audio generation succeeds\nthrough paired delivery.",
            agent_name="remote-agent",
            message="The audio is ready.",
            attachments=[],
        )
        self.assertIn(
            ["summary", "Hosted audio generation succeeds through paired delivery."],
            tags,
        )

        with self.assertRaisesRegex(RuntimeError, "must not exceed 10 words"):
            request_tags(
                peer_pubkey=pubkey_for_nsec("laptop-secret"),
                group_id="tts",
                title="MCP audio generation now works across every paired delivery path reliably",
                summary="This title is too long.",
                agent_name="remote-agent",
                message="This request should fail.",
                attachments=[],
            )

    def test_answer_tags_round_trip_multiple_values_without_ui_metadata(self) -> None:
        request = self.request()
        local_result = {
            "status": "answered",
            "questions": [{
                "id": "q-01",
                "status": "answered",
                "response": {
                    "answer": "Europe, North America",
                    "interaction": "suggestion",
                    "modified": False,
                    "selected_suggestions": [{"title": "Europe"}, {"title": "North America"}],
                    "attachments": [{"source_file": "/Users/private/answer.txt"}],
                },
            }, {
                "id": "q-02",
                "status": "answered",
                "response": {"answer": "Monday", "interaction": "freeform"},
            }],
        }
        answers = answers_from_result(local_result, request)
        tags = reply_tags(request, answers=answers)
        reply = fake_signed_event(
            kind=9,
            content=render_reply_content(request, tags),
            tags=tags,
            nsec="laptop-secret",
            relay="file://relay",
        )
        transport("file://relay").publish(reply)

        result = wait_for_answer(
            request_event=request,
            relay="file://relay",
            wait="1s",
        )

        self.assertEqual(result["status"], "answered")
        self.assertEqual(result["answers"], [
            {"id": "q-01", "values": ["Europe", "North America"]},
            {"id": "q-02", "values": ["Monday"]},
        ])
        self.assertEqual(reply["content"], (
            "# User has replied\n\n"
            "1. **Where should we deploy?** Europe, North America\n"
            "2. **When should deployment begin?** Monday"
        ))
        self.assertIn(["answer", "q-01", "Europe", "North America"], reply["tags"])
        self.assertNotIn("/Users/private", json.dumps(reply))
        self.assertFalse({"product", "request", "response", "status"}.intersection(
            tag[0] for tag in reply["tags"]
        ))

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

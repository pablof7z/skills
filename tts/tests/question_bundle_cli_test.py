#!/usr/bin/env python3
"""End-to-end contracts for structured TTS question bundles."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer

from tts.tests.tts_test_support import KokoroHandler


class QuestionBundleCLITests(unittest.TestCase):
    def setUp(self) -> None:
        with KokoroHandler.received_inputs_lock:
            KokoroHandler.received_inputs = []
            KokoroHandler.received_voices = []
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-question-bundle-")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.root / "state"
        self.sessions = self.root / "sessions"
        repository = Path(__file__).resolve().parents[2]
        self.tts = repository / "tts" / "scripts" / "tts"
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.environment = os.environ.copy()
        self.environment.update(
            HOME=str(self.home),
            KOKORO_API_ENDPOINT=f"http://127.0.0.1:{self.server.server_port}/v1/audio/speech",
            TTS_MACOS_MENU="0",
            TTS_SESSIONS_ROOT=str(self.sessions),
            TTS_STATE_DIR=str(self.state),
        )

    def tearDown(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()
        self.temporary.cleanup()

    def wait_for_item(self) -> Path:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            paths = list((self.state / "items").glob("*.json"))
            if paths:
                try:
                    item = json.loads(paths[0].read_text())
                    if item.get("status") == "queued":
                        return paths[0]
                except (OSError, ValueError):
                    pass
            time.sleep(0.05)
        self.fail("question bundle did not reach the durable queue")

    def answer_bundle(self, item_path: Path, answer_attachment: Path) -> None:
        lock_path = self.state / "operations.flock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            item = json.loads(item_path.read_text())
            item["questions"][0]["status"] = "answered"
            item["questions"][0]["response"] = {
                "answer": "Use the first direction with edits.",
                "suggestion_ids": ["q-01-s-01"],
                "modified": True,
                "answered_at": 42,
                "interaction": "suggestion_edited",
                "attachments": [{"source_file": str(answer_attachment)}],
            }
            item["questions"][1]["status"] = "skipped"
            item_path.write_text(json.dumps(item))
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def test_inline_bundle_copies_scoped_assets_and_returns_atomic_answers(self) -> None:
        question_context = self.root / "question.md"
        question_context.write_text("Question context body must not enter the main speech.")
        suggestion_context = self.root / "suggestion.txt"
        suggestion_context.write_text("Suggestion context body must not enter the main speech.")
        answer_attachment = self.root / "answer.txt"
        answer_attachment.write_text("The user's dropped answer attachment.")
        bundle = {
            "questions_preamble": "There are two rollout details to settle before release.",
            "questions": [
                {
                    "short_title": "Rollout",
                    "title": "Which rollout shape should we use?",
                    "description": "Balance reversibility and speed.",
                    "attachments": [str(question_context)],
                    "suggestions": [
                        {
                            "title": "Progressive rollout",
                            "description": "Start with a narrow cohort.",
                            "attachments": [{"path": str(suggestion_context), "description": "Prior evidence"}],
                        }
                    ],
                },
                {
                    "short_title": "Notifications",
                    "title": "Which teams should we notify?",
                    "type": "multiple_choice",
                    "suggestions": [{"title": "Support"}, {"title": "Operations"}],
                },
            ],
        }
        process = subprocess.Popen(
            [
                str(self.tts),
                "--agent-name",
                "question-bundle-test",
                "--subject",
                "Choosing the release rollout and notification plan",
                "--message",
                "The release is ready, but we still need to choose the rollout and notification plan.",
                "--wait",
                "5s",
                "--ask",
                json.dumps(bundle),
            ],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            item_path = self.wait_for_item()
            item = json.loads(item_path.read_text())
            self.assertEqual(
                item["questions_preamble"],
                "There are two rollout details to settle before release.",
            )
            self.assertEqual([q["id"] for q in item["questions"]], ["q-01", "q-02"])
            self.assertEqual(item["questions"][0]["type"], "single_choice")
            self.assertEqual(item["questions"][1]["type"], "multiple_choice")
            self.assertEqual(item["questions"][0]["short_title"], "Rollout")
            self.assertEqual(item["questions"][0]["suggestions"][0]["id"], "q-01-s-01")
            self.assertEqual(item["questions"][0]["attachments"][0]["status"], "ready")
            self.assertTrue(Path(item["questions"][0]["attachments"][0]["audio_file"]).is_file())
            self.assertEqual(item["questions"][0]["suggestions"][0]["attachments"][0]["status"], "ready")
            self.assertIsNone(item["attachments"])
            self.assertEqual(
                item["primary_message"],
                "The release is ready, but we still need to choose the rollout and notification plan.",
            )
            self.assertTrue(item["text"].startswith("The release is ready"))
            self.assertIn("two rollout details", item["text"])
            self.assertNotIn("Which rollout shape", item["text"])
            self.assertNotIn("Balance reversibility", item["text"])
            self.assertNotIn("Progressive rollout", item["text"])
            self.assertNotIn("context body", item["text"])
            with KokoroHandler.received_inputs_lock:
                spoken = next(
                    value for value in KokoroHandler.received_inputs
                    if "The release is ready" in value
                )
            self.assertIn("two rollout details", spoken)
            self.assertNotIn("Which rollout shape", spoken)
            self.assertNotIn("Balance reversibility", spoken)
            self.answer_bundle(item_path, answer_attachment)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertIn(
                "Blocking for up to 5s",
                stderr,
            )
            output = json.loads(stdout)
            self.assertEqual(output["status"], "answered")
            self.assertEqual(output["questions"][0]["response"]["suggestion_id"], "q-01-s-01")
            self.assertEqual(output["questions"][0]["response"]["suggestion_ids"], ["q-01-s-01"])
            self.assertEqual(output["questions"][1]["status"], "skipped")
            self.assertEqual(output["answer_attachment_paths"], [str(answer_attachment)])
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)

    def test_at_file_resolves_relative_attachments_and_legacy_ask_still_parses(self) -> None:
        fixture = self.root / "fixture"
        fixture.mkdir()
        (fixture / "context.txt").write_text("Relative context")
        payload = fixture / "questions.json"
        payload.write_text(json.dumps({
            "questions": [{
                "short_title": "Direction",
                "title": "Choose a direction",
                "attachments": ["context.txt"],
            }]
        }))
        process = subprocess.Popen(
            [
                str(self.tts),
                "--agent-name",
                "question-bundle-test",
                "--subject",
                "Choosing the release rollout and notification plan",
                "--message",
                "I reviewed the available direction and need your decision.",
                "--wait",
                "5s",
                "--ask",
                f"@{payload}",
            ],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            item_path = self.wait_for_item()
            item = json.loads(item_path.read_text())
            source = Path(item["questions"][0]["attachments"][0]["source_file"])
            self.assertTrue(source.is_file())
            self.assertEqual(source.read_text(), "Relative context")
            lock_path = self.state / "operations.flock"
            with lock_path.open("a+") as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                item["questions"][0]["status"] = "skipped"
                item_path.write_text(json.dumps(item))
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout)["status"], "skipped")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)

        invalid = subprocess.run(
            [str(self.tts), "--wait", "1s", "--ask", '{"questions": []}'],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("non-empty array", invalid.stderr)

        invalid_type = subprocess.run(
            [str(self.tts), "--wait", "1s", "--ask", '{"questions": [{"short_title": "Choice", "title": "Pick", "type": "ranked"}]}'],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(invalid_type.returncode, 0)
        self.assertIn("single_choice or multiple_choice", invalid_type.stderr)

        missing_message = subprocess.run(
            [str(self.tts), "--wait", "1s", "--ask", '{"questions": [{"short_title": "Choice", "title": "Pick one"}]}'],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(missing_message.returncode, 0)
        self.assertIn("requires --message", missing_message.stderr)

        missing_short_title = subprocess.run(
            [
                str(self.tts),
                "--message",
                "The implementation is ready.",
                "--wait",
                "1s",
                "--ask",
                '{"questions": [{"title": "Pick one"}]}',
            ],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(missing_short_title.returncode, 0)
        self.assertIn("short_title must be a non-empty string", missing_short_title.stderr)

        obsolete_root_fields = subprocess.run(
            [
                str(self.tts),
                "--message",
                "The implementation is ready.",
                "--wait",
                "1s",
                "--ask",
                '{"title": "Old hierarchy", "questions": [{"title": "Pick one"}]}',
            ],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(obsolete_root_fields.returncode, 0)
        self.assertIn("root no longer supports title", obsolete_root_fields.stderr)

        legacy = subprocess.run(
            [str(self.tts), "--ask", "Legacy question?", "--no-play"],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(legacy.returncode, 0)
        self.assertIn("not compatible", legacy.stderr)


if __name__ == "__main__":
    unittest.main()

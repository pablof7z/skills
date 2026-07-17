#!/usr/bin/env python3
"""Focused contracts for the agent-facing TTS queue CLI."""

from __future__ import annotations

import json
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from tts.tests.tts_test_support import BlockingKokoroHandler, KokoroHandler
from http.server import ThreadingHTTPServer


class QueueCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-queue-cli-")
        self.state = Path(self.temporary.name)
        (self.state / "items").mkdir()
        (self.state / "home").mkdir()
        repository = Path(__file__).resolve().parents[2]
        self.menu = repository / "tts" / "scripts" / "tts-menu"
        self.tts = repository / "tts" / "scripts" / "tts"
        self.environment = os.environ.copy()
        self.environment["HOME"] = str(self.state / "home")
        self.environment["TTS_STATE_DIR"] = str(self.state)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_question(self, item_id: str, created_at: int) -> None:
        value = {
            "id": item_id,
            "created_at": created_at,
            "status": "queued",
            "kind": "question",
            "question_status": "pending",
            "is_archived": False,
        }
        (self.state / "items" / f"{item_id}.json").write_text(json.dumps(value))

    def write_item(self, item_id: str, **overrides: object) -> None:
        value = {
            "id": item_id,
            "created_at": 1,
            "status": "queued",
            "kind": "speech",
            "is_archived": False,
        }
        value.update(overrides)
        (self.state / "items" / f"{item_id}.json").write_text(json.dumps(value))

    def run_menu(self, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.menu), "queue", *arguments],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_list_is_bounded_and_navigable(self) -> None:
        for index in range(25):
            self.write_question(f"q{index}", index)
        first = json.loads(self.run_menu("list").stdout)
        self.assertEqual(len(first["items"]), 20)
        self.assertEqual(first["pagination"]["total"], 25)
        self.assertEqual(first["pagination"]["next_offset"], 20)
        second = json.loads(self.run_menu("list", "--offset", "20").stdout)
        self.assertEqual(len(second["items"]), 5)
        self.assertIsNone(second["pagination"]["next_offset"])

    def test_supersede_is_terminal_and_audited(self) -> None:
        for index in range(3):
            self.write_question(f"q{index}", index)
        result = json.loads(
            self.run_menu(
                "supersede", "q0", "q1", "--superseded-by", "q2",
                "--reason", "Combined with missing nuance.",
            ).stdout
        )
        self.assertEqual(result["status"], "superseded")
        waited = json.loads(self.run_menu("wait", "q0", "--timeout", "0.1").stdout)
        self.assertEqual(waited["superseded_by"], ["q2"])
        self.assertEqual(len(list((self.state / "operations").glob("*.json"))), 1)

    def test_archive_terminalizes_requested_items_and_their_attachments(self) -> None:
        self.write_item("parent", status="playing")
        self.write_item(
            "child",
            status="queued",
            parent_item_id="parent",
            attachment_id="attachment-1",
        )
        self.write_item("other")

        result = json.loads(
            self.run_menu("archive", "parent", "--reason", "No longer needed.").stdout
        )

        self.assertEqual(result["ids"], ["child", "parent"])
        for item_id in result["ids"]:
            item = json.loads((self.state / "items" / f"{item_id}.json").read_text())
            self.assertTrue(item["is_archived"])
            self.assertEqual(item["status"], "interrupted")
            self.assertIsNotNone(item["completed_at"])
        other = json.loads((self.state / "items" / "other.json").read_text())
        self.assertFalse(other["is_archived"])
        self.assertEqual(other["status"], "queued")

        operations = list((self.state / "operations").glob("*.json"))
        self.assertEqual(len(operations), 1)
        operation = json.loads(operations[0].read_text())
        self.assertEqual(operation["source_ids"], ["child", "parent"])

    def test_archive_validates_the_whole_batch_before_writing(self) -> None:
        self.write_item("valid")

        result = self.run_menu(
            "archive", "valid", "missing", "--reason", "Batch request.", check=False
        )

        self.assertEqual(result.returncode, 2)
        valid = json.loads((self.state / "items" / "valid.json").read_text())
        self.assertFalse(valid["is_archived"])
        self.assertEqual(valid["status"], "queued")
        self.assertFalse((self.state / "operations").exists())

    def test_wait_includes_the_users_answer(self) -> None:
        self.write_question("answered", 1)
        path = self.state / "items" / "answered.json"
        item = json.loads(path.read_text())
        item["question_status"] = "answered"
        item["response"] = {
            "answer": "Use the split model, with one small change.",
            "suggestion_index": 1,
            "modified": True,
            "answered_at": 42,
            "interaction": "suggestion_edited",
        }
        path.write_text(json.dumps(item))
        result = json.loads(self.run_menu("wait", "answered", "--timeout", "1s").stdout)
        self.assertEqual(result["status"], "answered")
        self.assertEqual(result["answer"], item["response"]["answer"])
        self.assertTrue(result["modified"])

    def test_wait_treats_generated_speech_as_terminal(self) -> None:
        value = {
            "id": "generated",
            "created_at": 1,
            "status": "generated",
            "kind": "speech",
            "question_status": None,
        }
        (self.state / "items" / "generated.json").write_text(json.dumps(value))
        result = json.loads(self.run_menu("wait", "generated", "--timeout", "0.1").stdout)
        self.assertEqual(result, {"id": "generated", "status": "generated"})

    def test_wait_requires_a_bound_and_returns_follow_up_guidance(self) -> None:
        self.write_question("pending", 1)
        missing = self.run_menu("wait", "pending", check=False)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("--timeout", missing.stderr)

        result = json.loads(
            self.run_menu("wait", "pending", "--timeout", "0.01s").stdout
        )
        self.assertEqual(result["status"], "pending")
        self.assertEqual(result["waited_seconds"], 0.01)
        self.assertIn("user hasn't replied after 0.01 seconds", result["guidance"])
        self.assertIn("--timeout 0.01s", result["wait_command"])

    def test_supersede_rejects_transitive_cycles(self) -> None:
        for index in range(3):
            self.write_question(f"cycle{index}", index)
        for source, replacement in (("cycle0", "cycle1"), ("cycle1", "cycle2")):
            path = self.state / "items" / f"{source}.json"
            item = json.loads(path.read_text())
            item["question_status"] = "superseded"
            item["superseded_by"] = [replacement]
            path.write_text(json.dumps(item))
        result = self.run_menu(
            "supersede", "cycle2", "--superseded-by", "cycle0",
            "--reason", "This would form a cycle.", check=False,
        )
        self.assertEqual(result.returncode, 3)
        self.assertIn("cycle", result.stderr)

    def test_queue_get_waits_for_shared_operations_lock(self) -> None:
        self.write_question("locked", 1)
        lock_path = self.state / "operations.flock"
        with lock_path.open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            process = subprocess.Popen(
                [str(self.menu), "queue", "get", "locked"],
                env=self.environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertIsNone(process.poll())
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        stdout, stderr = process.communicate(timeout=2)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(json.loads(stdout)["id"], "locked")

    def test_ask_rejects_no_play_and_validates_suggestions(self) -> None:
        conflict = subprocess.run(
            [str(self.tts), "--ask", "--no-play", "Question?"],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(conflict.returncode, 0)
        self.assertIn("not compatible", conflict.stderr)
        invalid = subprocess.run(
            [str(self.tts), "--ask", "--wait", "1s", "--suggestions", '["bad"]', "Question?"],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("must be [title, description]", invalid.stderr)

        missing_wait = subprocess.run(
            [str(self.tts), "--ask", "Question?"],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(missing_wait.returncode, 0)
        self.assertIn("requires --wait", missing_wait.stderr)

    def test_no_play_emits_stable_structured_id_and_persists_it(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            environment = self.environment.copy()
            environment["KOKORO_API_ENDPOINT"] = (
                f"http://127.0.0.1:{server.server_port}/v1/audio/speech"
            )
            environment["TTS_SESSIONS_ROOT"] = str(self.state / "sessions")
            result = subprocess.run(
                [
                    str(self.tts),
                    "--agent-name",
                    "structured-output-test",
                    "--subject",
                    "Testing stable structured output from TTS generation",
                    "--summary",
                    "Generated output retains a stable structured contract.",
                    "--no-play",
                    "--message",
                    "Structured output test.",
                ],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            output = json.loads(result.stdout)
            self.assertTrue(output["id"])
            self.assertEqual(output["status"], "generated")
            item = json.loads(
                (self.state / "items" / f"{output['id']}.json").read_text()
            )
            self.assertEqual(item["id"], output["id"])
            self.assertEqual(item["status"], "generated")
            self.assertFalse(item["playback_requested"])
            self.assertEqual(list((self.state / "playback-admissions").glob("*.json")), [])
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_generation_transition_preserves_locked_queue_mutation(self) -> None:
        BlockingKokoroHandler.request_started = threading.Event()
        BlockingKokoroHandler.release_response = threading.Event()
        server = ThreadingHTTPServer(("127.0.0.1", 0), BlockingKokoroHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        process: subprocess.Popen[str] | None = None
        try:
            environment = self.environment.copy()
            environment["KOKORO_API_ENDPOINT"] = (
                f"http://127.0.0.1:{server.server_port}/v1/audio/speech"
            )
            environment["TTS_SESSIONS_ROOT"] = str(self.state / "sessions")
            process = subprocess.Popen(
                [
                    str(self.tts),
                    "--agent-name",
                    "queue-transition-test",
                    "--subject",
                    "Testing locked queue transitions during TTS generation",
                    "--summary",
                    "Queue transitions remain locked during concurrent generation updates.",
                    "--no-play",
                    "--message",
                    "Lock transition test.",
                ],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertTrue(BlockingKokoroHandler.request_started.wait(timeout=2))
            item_path = next((self.state / "items").glob("*.json"))
            lock_path = self.state / "operations.flock"
            with lock_path.open("a+") as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                item = json.loads(item_path.read_text())
                item.update(
                    is_archived=True,
                    archived_at=123,
                    archive_reason="Concurrent queue decision.",
                )
                item_path.write_text(json.dumps(item))
                BlockingKokoroHandler.release_response.set()
                self.assertIsNone(process.poll())
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            stdout, stderr = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 0, stderr)
            final = json.loads(item_path.read_text())
            self.assertEqual(final["status"], "generated")
            self.assertFalse(final["playback_requested"])
            self.assertTrue(final["is_archived"])
            self.assertEqual(final["archive_reason"], "Concurrent queue decision.")
            self.assertEqual(final["id"], json.loads(stdout)["id"])
        finally:
            BlockingKokoroHandler.release_response.set()
            if process is not None and process.poll() is None:
                process.kill()
                process.communicate(timeout=2)
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()


if __name__ == "__main__":
    unittest.main()

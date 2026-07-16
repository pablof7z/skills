#!/usr/bin/env python3
"""End-to-end native-tag paired ask contract."""

from __future__ import annotations

import fcntl
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

from tts.tests.tts_test_support import KokoroHandler


class RemoteAskRoundTripCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-remote-round-trip-")
        self.root = Path(self.temporary.name)
        self.laptop = self.root / "laptop"
        self.server = self.root / "server"
        (self.laptop / "home").mkdir(parents=True)
        (self.server / "home").mkdir(parents=True)
        self.transport_file = self.root / "transport.jsonl"
        self.tts = Path(__file__).resolve().parents[1] / "scripts" / "tts"
        self.kokoro = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        self.kokoro_thread = threading.Thread(target=self.kokoro.serve_forever, daemon=True)
        self.kokoro_thread.start()

    def tearDown(self) -> None:
        self.run_tts("daemon", "stop", state=self.laptop, check=False)
        self.kokoro.shutdown()
        self.kokoro_thread.join(timeout=2)
        self.kokoro.server_close()
        self.temporary.cleanup()

    def environment(self, state: Path) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update({
            "HOME": str(state / "home"),
            "TTS_STATE_DIR": str(state),
            "TTS_SESSIONS_ROOT": str(state / "sessions"),
            "TTS_REMOTE_TRANSPORT": "file",
            "TTS_REMOTE_TRANSPORT_FILE": str(self.transport_file),
            "TTS_REMOTE_NO_MENU": "1",
            "TTS_GROUP_CONFIRM_TIMEOUT_SECONDS": "3",
            "TTS_REMOTE_ASK_DELIVERY_SECONDS": "2",
        })
        return environment

    def run_tts(
        self,
        *arguments: str,
        state: Path,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.tts), *arguments],
            env=self.environment(state),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def pair(self) -> str:
        offer = json.loads(self.run_tts("pair", "offer", state=self.laptop).stdout)
        self.run_tts("daemon", "start", state=self.laptop)
        connected = json.loads(
            self.run_tts("pair", "connect", "--code", offer["pair_code"], state=self.server).stdout
        )
        self.run_tts("daemon", "stop", state=self.laptop)
        return str(connected["peer"]["pubkey"])

    def wait_for_request(self) -> dict[str, object]:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.transport_file.is_file():
                events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
                request = next(
                    (event for event in reversed(events) if any(tag[0] == "question" for tag in event["tags"])),
                    None,
                )
                if request:
                    return request
            time.sleep(0.05)
        self.fail("remote ask request was not published")

    def answer_when_present(self, item_path: Path) -> None:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if item_path.is_file():
                lock_path = self.laptop / "operations.flock"
                with lock_path.open("a+") as lock:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                    item = json.loads(item_path.read_text())
                    item["questions"][0]["status"] = "answered"
                    item["questions"][0]["response"] = {
                        "answer": "Europe, North America",
                        "selected_suggestions": [{"title": "Europe"}, {"title": "North America"}],
                    }
                    item["questions"][1]["status"] = "answered"
                    item["questions"][1]["response"] = {"answer": "Monday"}
                    item_path.write_text(json.dumps(item))
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                return
            time.sleep(0.05)
        self.fail("paired ask did not materialize")

    def test_markdown_request_returns_native_answer_tags(self) -> None:
        peer = self.pair()
        bundle = json.dumps({
            "questions_preamble": "Settle the remaining deployment details.",
            "questions": [{
                "short_title": "Regions",
                "title": "Where should we deploy?",
                "type": "multiple_choice",
                "suggestions": [{"title": "Europe"}, {"title": "North America"}],
            }, {
                "short_title": "Timing",
                "title": "When should deployment begin?",
                "suggestions": [{"title": "Monday"}],
            }],
        })
        remote = subprocess.Popen(
            [
                str(self.tts), "remote", "speak", "--peer", peer,
                "--agent-name", "Codex", "--subject", "Choose the deployment regions",
                "--message", "The release is ready for a deployment decision.",
                "--ask", bundle, "--wait", "5s",
            ],
            env=self.environment(self.server),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        daemon = None
        try:
            request = self.wait_for_request()
            daemon_environment = self.environment(self.laptop)
            daemon_environment.update({
                "KOKORO_API_ENDPOINT": (
                    f"http://127.0.0.1:{self.kokoro.server_port}/v1/audio/speech"
                ),
                "TTS_MACOS_MENU": "0",
                "TTS_REMOTE_DAEMON_NO_PLAY": "1",
            })
            daemon = subprocess.Popen(
                [str(self.tts), "daemon", "run", "--once", "--max-events", "1"],
                env=daemon_environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.answer_when_present(self.laptop / "items" / f"{request['id']}.json")
            daemon_stdout, daemon_stderr = daemon.communicate(timeout=8)
            remote_stdout, remote_stderr = remote.communicate(timeout=8)
            self.assertEqual(daemon.returncode, 0, daemon_stderr)
            self.assertEqual(remote.returncode, 0, remote_stderr)
            self.assertEqual(json.loads(daemon_stdout)["processed"], 1)
            output = json.loads(remote_stdout)
            self.assertEqual(output["status"], "answered")
            self.assertEqual(output["answers"], [
                {"id": "q-01", "values": ["Europe", "North America"]},
                {"id": "q-02", "values": ["Monday"]},
            ])

            events = [json.loads(line) for line in self.transport_file.read_text().splitlines()]
            reply = events[-1]
            self.assertTrue(str(request["content"]).startswith("# Choose the deployment regions\n"))
            self.assertIn(["answer", "q-01", "Europe", "North America"], reply["tags"])
            self.assertEqual({tag[0] for tag in reply["tags"]}, {"e", "p", "h", "answer"})
            self.assertNotIn("{\"questions\"", json.dumps(request["tags"]))
            self.assertNotIn("{\"questions\"", json.dumps(reply["tags"]))
        finally:
            for process in (daemon, remote):
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=2)


if __name__ == "__main__":
    unittest.main()

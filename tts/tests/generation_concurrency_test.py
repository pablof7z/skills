#!/usr/bin/env python3
"""Cross-process concurrency contracts for Kokoro generation."""

from __future__ import annotations

from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

from tts.tests.tts_test_support import KokoroHandler


class ConcurrencyTrackingKokoroHandler(KokoroHandler):
    condition = threading.Condition()
    release_responses = threading.Event()
    active_requests = 0
    peak_requests = 0
    request_count = 0

    @classmethod
    def reset(cls) -> None:
        cls.release_responses = threading.Event()
        with cls.condition:
            cls.active_requests = 0
            cls.peak_requests = 0
            cls.request_count = 0

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        handler = type(self)
        with handler.condition:
            handler.active_requests += 1
            handler.request_count += 1
            handler.peak_requests = max(handler.peak_requests, handler.active_requests)
            handler.condition.notify_all()
        try:
            handler.release_responses.wait(timeout=10)
            super().do_POST()
        finally:
            with handler.condition:
                handler.active_requests -= 1
                handler.condition.notify_all()


class GenerationConcurrencyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-generation-limit-")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.root / "state"
        self.sessions = self.root / "sessions"
        repository = Path(__file__).resolve().parents[2]
        self.tts = repository / "tts" / "scripts" / "tts"
        ConcurrencyTrackingKokoroHandler.reset()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), ConcurrencyTrackingKokoroHandler)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.processes: list[subprocess.Popen[str]] = []

    def tearDown(self) -> None:
        ConcurrencyTrackingKokoroHandler.release_responses.set()
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=2)
        self.server.shutdown()
        self.server_thread.join(timeout=2)
        self.server.server_close()
        self.temporary.cleanup()

    def environment(self, limit: int | None = None) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(self.home),
                "KOKORO_API_ENDPOINT": (
                    f"http://127.0.0.1:{self.server.server_port}/v1/audio/speech"
                ),
                "TTS_MACOS_MENU": "0",
                "TTS_SESSIONS_ROOT": str(self.sessions),
                "TTS_STATE_DIR": str(self.state),
                "TTS_GENERATION_SLOT_POLL_SECONDS": "0.02",
            }
        )
        environment.pop("TTS_MAX_PARALLEL_GENERATIONS", None)
        if limit is not None:
            environment["TTS_MAX_PARALLEL_GENERATIONS"] = str(limit)
        return environment

    def launch(self, count: int, limit: int | None = None) -> None:
        environment = self.environment(limit)
        for index in range(count):
            self.processes.append(
                subprocess.Popen(
                    [
                        str(self.tts),
                        "--no-play",
                        "--agent-name",
                        "concurrency-test",
                        "--subject",
                        f"Concurrent generation request number {index} now",
                        "--message",
                        "This request should respect the shared generation limit.",
                    ],
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            )

    def wait_for_request_count(self, expected: int) -> bool:
        with ConcurrencyTrackingKokoroHandler.condition:
            return ConcurrencyTrackingKokoroHandler.condition.wait_for(
                lambda: ConcurrencyTrackingKokoroHandler.request_count >= expected,
                timeout=5,
            )

    def finish_processes(self) -> None:
        ConcurrencyTrackingKokoroHandler.release_responses.set()
        for process in self.processes:
            stdout, stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0, stderr or stdout)

    def test_defaults_to_two_parallel_generations_across_processes(self) -> None:
        self.launch(4)
        self.assertTrue(self.wait_for_request_count(2))
        time.sleep(0.25)
        self.assertEqual(ConcurrencyTrackingKokoroHandler.request_count, 2)
        self.assertEqual(ConcurrencyTrackingKokoroHandler.peak_requests, 2)

        self.finish_processes()
        self.assertEqual(ConcurrencyTrackingKokoroHandler.request_count, 4)
        self.assertEqual(ConcurrencyTrackingKokoroHandler.peak_requests, 2)

    def test_configured_limit_is_shared_by_independent_processes(self) -> None:
        self.launch(2, limit=1)
        self.assertTrue(self.wait_for_request_count(1))
        time.sleep(0.25)
        self.assertEqual(ConcurrencyTrackingKokoroHandler.request_count, 1)

        self.finish_processes()
        self.assertEqual(ConcurrencyTrackingKokoroHandler.request_count, 2)
        self.assertEqual(ConcurrencyTrackingKokoroHandler.peak_requests, 1)

    def test_dead_process_slot_is_recovered(self) -> None:
        stale_slot = self.state / "generation-slots" / "slot-1"
        stale_slot.mkdir(parents=True)
        (stale_slot / "owner").write_text("999999999\n0\n", encoding="utf-8")

        self.launch(1, limit=1)
        self.assertTrue(self.wait_for_request_count(1))
        self.finish_processes()
        self.assertFalse(stale_slot.exists())

    def test_rejects_non_positive_limit_before_calling_kokoro(self) -> None:
        self.launch(1, limit=0)
        process = self.processes[0]
        stdout, stderr = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0, stdout)
        self.assertIn("must be a positive integer", stderr)
        self.assertEqual(ConcurrencyTrackingKokoroHandler.request_count, 0)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Regression contracts for local TTS playback ownership."""

from __future__ import annotations

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


class PlaybackOwnershipTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-playback-owner-")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.root / "state"
        self.sessions = self.root / "sessions"
        self.repository = Path(__file__).resolve().parents[2]
        self.tts_command = self.repository / "tts" / "scripts" / "tts"
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir()
        self.afplay_marker = self.root / "afplay-called"
        afplay = self.fake_bin / "afplay"
        afplay.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$1\" > \"$AFPLAY_MARKER\"\n",
            encoding="utf-8",
        )
        afplay.chmod(0o755)
        self.menu_log = self.root / "menu.log"
        self.fake_menu = self.root / "tts-menu"
        self.fake_menu.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$MENU_LOG\"\nexit \"${MENU_EXIT:-0}\"\n",
            encoding="utf-8",
        )
        self.fake_menu.chmod(0o755)
        self.audio = self.root / "existing.mp3"
        self.audio.write_bytes(b"existing-audio")

        self.environment = os.environ.copy()
        self.environment.update(
            {
                "AFPLAY_MARKER": str(self.afplay_marker),
                "HOME": str(self.home),
                "MENU_LOG": str(self.menu_log),
                "PATH": f"{self.fake_bin}:{self.environment['PATH']}",
                "TTS_MACOS_MENU": "1",
                "TTS_MENU_COMMAND": str(self.fake_menu),
                "TTS_SESSIONS_ROOT": str(self.sessions),
                "TTS_SESSION_ID": "playback-owner-test",
                "TTS_STATE_DIR": str(self.state),
            }
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_existing(
        self,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(self.tts_command),
                "--agent-name",
                "playback-owner-test",
                "--subject",
                "Existing Audio Routed",
                "--summary",
                "Existing audio uses the same durable macOS playback owner.",
                "--play-existing",
                str(self.audio),
            ],
            env=environment or self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_existing_file_is_queued_without_calling_afplay(self) -> None:
        result = self.run_existing()

        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["status"], "queued")
        item_path = self.state / "items" / f"{response['id']}.json"
        item = json.loads(item_path.read_text(encoding="utf-8"))
        self.assertEqual(item["status"], "queued")
        self.assertEqual(item["subject"], "Existing Audio Routed")
        self.assertEqual(Path(item["output_file"]).read_bytes(), b"existing-audio")
        self.assertTrue(Path(item["output_file"]).is_relative_to(self.sessions))
        self.assertEqual(self.menu_log.read_text(encoding="utf-8").splitlines(), ["start"])
        self.assertFalse(self.afplay_marker.exists())

    def test_direct_player_requires_explicit_macos_player_opt_out(self) -> None:
        environment = self.environment | {"TTS_MACOS_MENU": "0"}

        result = self.run_existing(environment)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.afplay_marker.read_text(encoding="utf-8").strip(), str(self.audio))
        self.assertFalse(self.menu_log.exists())

    def test_generated_audio_does_not_bypass_an_unavailable_macos_player(self) -> None:
        with KokoroHandler.received_inputs_lock:
            KokoroHandler.received_inputs = []
            KokoroHandler.received_voices = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            environment = self.environment | {
                "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                "MENU_EXIT": "1",
            }
            result = subprocess.run(
                [
                    str(self.tts_command),
                    "--agent-name",
                    "playback-owner-test",
                    "--subject",
                    "Generated Audio Routed",
                    "--summary",
                    "Generated audio fails visibly when its playback owner is unavailable.",
                    "--message",
                    "This audio must not bypass the macOS player.",
                ],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("macOS playback owner", result.stderr)
            self.assertFalse(self.afplay_marker.exists())
            item_paths = list((self.state / "items").glob("*.json"))
            self.assertEqual(len(item_paths), 1)
            item = json.loads(item_paths[0].read_text(encoding="utf-8"))
            self.assertEqual(item["status"], "failed")
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_generated_audio_keeps_explicit_direct_playback_opt_out(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), KokoroHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            environment = self.environment | {
                "KOKORO_API_ENDPOINT": f"http://127.0.0.1:{server.server_port}/v1/audio/speech",
                "TTS_MACOS_MENU": "0",
            }
            result = subprocess.run(
                [
                    str(self.tts_command),
                    "--agent-name",
                    "playback-owner-test",
                    "--subject",
                    "Direct Playback Opt Out",
                    "--summary",
                    "Explicitly disabled macOS ownership retains direct playback.",
                    "--message",
                    "This audio intentionally uses direct playback.",
                ],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            response = json.loads(result.stdout)
            self.assertEqual(response["status"], "queued")
            deadline = time.monotonic() + 2
            while not self.afplay_marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(self.afplay_marker.exists())
            self.assertFalse(self.menu_log.exists())
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_synthesis_module_does_not_start_audio(self) -> None:
        synthesis = (
            self.repository / "tts" / "scripts" / "tts-synthesis.sh"
        ).read_text(encoding="utf-8")

        self.assertNotIn("afplay", synthesis)
        self.assertNotIn("xdg-open", synthesis)


if __name__ == "__main__":
    unittest.main()

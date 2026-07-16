from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WTG = ROOT / "bin" / "wtg"


class RemoteDaemonTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.temp = Path(self.tempdir.name)
        self.state = self.temp / "server-state.json"
        self.env = os.environ.copy()
        self.env.update(
            {
                "WTG_TRANSPORT": "fake",
                "WTG_FAKE_RELAY_FILE": str(self.temp / "relay.jsonl"),
                "WTG_STATE_FILE": str(self.state),
                "PYTHONPATH": str(ROOT / "lib"),
            }
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_wtg(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(WTG), *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            check=False,
        )

    def test_daemon_start_status_stop_clears_running_state(self) -> None:
        start = self.run_wtg("daemon", "server", "start", "--timeout", "30")
        self.assertEqual(start.returncode, 0, start.stderr)
        try:
            started = json.loads(start.stdout)
            self.assertTrue(started["running"])
            self.assertTrue(started["pid"])
            status = self.run_wtg("daemon", "server", "status")
            payload = json.loads(status.stdout)
            self.assertTrue(payload["running"])
            self.assertEqual(payload["pid"], started["pid"])
        finally:
            stop = self.run_wtg("daemon", "server", "stop")
        self.assertEqual(stop.returncode, 0, stop.stderr)
        self.assertFalse(json.loads(stop.stdout)["running"])
        self.assertFalse(json.loads(self.run_wtg("daemon", "server", "status").stdout)["running"])


if __name__ == "__main__":
    unittest.main()

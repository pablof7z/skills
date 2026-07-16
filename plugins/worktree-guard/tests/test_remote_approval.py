from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WTG = ROOT / "bin" / "wtg"
sys.path.insert(0, str(ROOT / "lib"))


class RemoteApprovalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.old_env = os.environ.copy()
        self.temp = Path(self.tempdir.name)
        self.state = self.temp / "state.json"
        self.relay = self.temp / "relay.jsonl"
        self.env = os.environ.copy()
        self.env.update(
            {
                "WTG_STATE_FILE": str(self.state),
                "WTG_TRANSPORT": "fake",
                "WTG_FAKE_RELAY_FILE": str(self.relay),
                "PYTHONPATH": str(ROOT / "lib"),
            }
        )
        os.environ.update(self.env)

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.tempdir.cleanup()

    def run_wtg(self, *args: str, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(WTG), *args],
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            check=False,
        )

    def test_pair_offer_code_contains_raw_secret_context(self) -> None:
        result = self.run_wtg("pair", "offer", "--relay", "fake://relay", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        code = payload["pair_code"]

        decoded = json.loads(code)
        self.assertEqual(decoded["version"], 1)
        self.assertEqual(decoded["product"], "worktree-guard")
        self.assertEqual(decoded["relay"], "fake://relay")
        self.assertEqual(decoded["laptop_pubkey"], payload["laptop_pubkey"])
        self.assertTrue(decoded["pairing_id"])
        self.assertTrue(decoded["secret"])
        self.assertGreater(decoded["expires_at"], decoded["created_at"])

    def test_pair_connect_persists_backend_and_peer(self) -> None:
        offer = json.loads(
            self.run_wtg("pair", "offer", "--relay", "fake://relay", "--json").stdout
        )
        result = self.run_wtg("pair", "connect", offer["pair_code"], "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        state = json.loads(self.state.read_text(encoding="utf-8"))

        self.assertEqual(payload["status"], "paired")
        self.assertEqual(state["remote"]["backend"]["pubkey"], payload["backend_pubkey"])
        self.assertIn(offer["laptop_pubkey"], state["remote"]["approved_peers"])
        events = [json.loads(line) for line in self.relay.read_text(encoding="utf-8").splitlines()]
        self.assertTrue(any(event["kind"] == 0 for event in events))
        pair_events = [event for event in events if event["kind"] == 9001]
        self.assertEqual(len(pair_events), 1)
        self.assertEqual(json.loads(pair_events[0]["content"])["secret"], offer["secret"])

    def test_correlated_remote_decision_creates_grant_once(self) -> None:
        from worktreeguard_lite.remote_approval import (
            RemoteApprovalRequest,
            publish_decision,
            request_remote_approval,
        )
        from worktreeguard_lite.remote_pairing import connect_pair_code, create_pair_offer
        from worktreeguard_lite.storage import load_state

        offer = create_pair_offer(relay="fake://relay")
        connect_pair_code(offer.pair_code)
        request = RemoteApprovalRequest(
            operation="apply_patch",
            worktree="/repo",
            repository="/repo",
            reason="issue #191 emergency base repair",
            session="session-1",
            ttl_seconds=60,
        )
        first = request_remote_approval(request, wait_seconds=0)
        self.assertIsNone(first)
        publish_decision(first_request_id(), "allow-session", peer_pubkey=offer.laptop_pubkey)
        decision = request_remote_approval(request, wait_seconds=1, request_id=first_request_id())

        self.assertEqual(decision, "session")
        self.assertEqual(len(load_state()["grants"]), 1)
        replay = request_remote_approval(request, wait_seconds=0, request_id=first_request_id())
        self.assertIsNone(replay)
        self.assertEqual(len(load_state()["grants"]), 1)


def first_request_id() -> str:
    events = [
        json.loads(line)
        for line in Path(os.environ["WTG_FAKE_RELAY_FILE"]).read_text(encoding="utf-8").splitlines()
    ]
    requests = [event for event in events if event["kind"] == 9]
    return requests[0]["id"]


if __name__ == "__main__":
    unittest.main()

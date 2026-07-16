from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
import stat
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


ROOT = Path(__file__).resolve().parents[1]
WTG = ROOT / "bin" / "wtg"
sys.path.insert(0, str(ROOT / "lib"))


class RemoteApprovalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.old_env = os.environ.copy()
        self.temp = Path(self.tempdir.name)
        self.laptop_state = self.temp / "laptop-state.json"
        self.server_state = self.temp / "server-state.json"
        self.other_server_state = self.temp / "other-server-state.json"
        self.relay = self.temp / "relay.jsonl"
        self.base_env = os.environ.copy()
        self.base_env.update(
            {
                "WTG_TRANSPORT": "fake",
                "WTG_FAKE_RELAY_FILE": str(self.relay),
                "PYTHONPATH": str(ROOT / "lib"),
            }
        )
        os.environ.update(self.env_for(self.laptop_state))

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.tempdir.cleanup()

    def env_for(self, state: Path) -> dict[str, str]:
        env = dict(self.base_env)
        env["WTG_STATE_FILE"] = str(state)
        return env

    @contextmanager
    def state_env(self, state: Path) -> Iterator[None]:
        previous = os.environ.copy()
        os.environ.clear()
        os.environ.update(self.env_for(state))
        try:
            yield
        finally:
            os.environ.clear()
            os.environ.update(previous)

    def run_wtg(
        self,
        *args: str,
        state: Path | None = None,
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = self.env_for(state or self.laptop_state)
        return subprocess.run(
            [str(WTG), *args],
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
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
        self.assertEqual(stat.S_IMODE(self.laptop_state.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.laptop_state.stat().st_mode), 0o600)

    def test_pair_connect_persists_backend_and_peer(self) -> None:
        offer = json.loads(self.run_wtg("pair", "offer", "--relay", "fake://relay", "--json").stdout)
        result = self.run_wtg("pair", "connect", offer["pair_code"], "--json", state=self.server_state)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        state = json.loads(self.server_state.read_text(encoding="utf-8"))

        self.assertEqual(payload["status"], "paired")
        self.assertEqual(state["remote"]["backend"]["pubkey"], payload["backend_pubkey"])
        self.assertIn(offer["laptop_pubkey"], state["remote"]["approved_peers"])
        events = [json.loads(line) for line in self.relay.read_text(encoding="utf-8").splitlines()]
        self.assertTrue(any(event["kind"] == 0 for event in events))
        pair_events = [event for event in events if event["kind"] == 9001]
        self.assertEqual(len(pair_events), 1)
        self.assertEqual(json.loads(pair_events[0]["content"])["secret"], offer["secret"])

    def test_laptop_signed_decision_creates_authoritative_server_grant_once(self) -> None:
        from worktreeguard_lite.remote_approval import (
            RemoteApprovalRequest,
            publish_decision,
            request_remote_approval,
        )
        from worktreeguard_lite.remote_pairing import connect_pair_code, create_pair_offer
        from worktreeguard_lite.storage import has_valid_grant, load_state

        with self.state_env(self.laptop_state):
            offer = create_pair_offer(relay="fake://relay")
        with self.state_env(self.server_state):
            connect_pair_code(offer.pair_code)
        with self.state_env(self.laptop_state):
            requests = []
            from worktreeguard_lite.remote_approval import laptop_requests

            requests = laptop_requests(0)
        self.assertEqual(requests, [])

        request = RemoteApprovalRequest(
            operation="apply_patch",
            worktree="/repo",
            repository="/repo",
            reason="issue #191 emergency base repair",
            session="session-1",
            ttl_seconds=60,
        )
        with self.state_env(self.server_state):
            first = request_remote_approval(request, wait_seconds=0)
            self.assertIsNone(first)
            request_id = first_request_id()
        with self.state_env(self.laptop_state):
            requests = laptop_requests(0)
            self.assertEqual([item["id"] for item in requests], [request_id])
            publish_decision(request_id, "allow-session")
        with self.state_env(self.server_state):
            decision = request_remote_approval(request, wait_seconds=1, request_id=request_id)
            self.assertEqual(decision, "session")
            self.assertEqual(len(load_state()["grants"]), 1)
            self.assertTrue(has_valid_grant(Path("/repo"), session_id="session-1"))
            self.assertFalse(has_valid_grant(Path("/repo"), session_id="session-2"))
            replay = request_remote_approval(request, wait_seconds=0, request_id=request_id)
            self.assertIsNone(replay)
            self.assertEqual(len(load_state()["grants"]), 1)

    def test_forged_wrong_target_cross_product_replay_and_late_decisions_fail_closed(self) -> None:
        from worktreeguard_lite.remote_approval import RemoteApprovalRequest, publish_decision, request_remote_approval
        from worktreeguard_lite.remote_events import APPROVAL_KIND, PRODUCT, signed_event
        from worktreeguard_lite.remote_pairing import connect_pair_code, create_pair_offer, identity
        from worktreeguard_lite.storage import load_state, save_state

        with self.state_env(self.laptop_state):
            offer = create_pair_offer(relay="fake://relay")
            laptop = identity(load_state(), "laptop")
        with self.state_env(self.server_state):
            connect_pair_code(offer.pair_code)
            backend = identity(load_state(), "backend")
            request = RemoteApprovalRequest("apply_patch", "/repo", "/repo", "#191", "s1", 60)
            request_remote_approval(request, wait_seconds=0)
            request_id = first_request_id()

        def publish_bad(secret: str, pubkey: str, tags: list[list[str]], content: dict[str, object]) -> None:
            event = signed_event(kind=APPROVAL_KIND, secret=secret, tags=tags, content=content)
            self.append_event(dict(event, pubkey=pubkey))

        publish_bad(
            "not-the-laptop",
            "forged-author",
            [["e", request_id], ["p", backend["pubkey"]], ["h", PRODUCT], ["product", PRODUCT]],
            {"decision": "allow-session", "request_id": request_id, "product": PRODUCT},
        )
        publish_bad(
            laptop["secret"],
            laptop["pubkey"],
            [["e", request_id], ["p", "wrong-backend"], ["h", PRODUCT], ["product", PRODUCT]],
            {"decision": "allow-session", "request_id": request_id, "product": PRODUCT},
        )
        publish_bad(
            laptop["secret"],
            laptop["pubkey"],
            [["e", "wrong-request"], ["p", backend["pubkey"]], ["h", PRODUCT], ["product", PRODUCT]],
            {"decision": "allow-session", "request_id": request_id, "product": PRODUCT},
        )
        publish_bad(
            laptop["secret"],
            laptop["pubkey"],
            [["e", request_id], ["p", backend["pubkey"]], ["h", "other"], ["product", "other"]],
            {"decision": "allow-session", "request_id": request_id, "product": "other"},
        )
        with self.state_env(self.server_state):
            self.assertIsNone(request_remote_approval(request, wait_seconds=0, request_id=request_id))
            self.assertEqual(load_state()["grants"], [])
        with self.state_env(self.laptop_state):
            publish_decision(request_id, "allow-once")
        with self.state_env(self.server_state):
            self.assertEqual(request_remote_approval(request, wait_seconds=0, request_id=request_id), "once")
            self.assertEqual(len(load_state()["grants"]), 1)
            self.assertIsNone(request_remote_approval(request, wait_seconds=0, request_id=request_id))
            self.assertEqual(len(load_state()["grants"]), 1)
            state = load_state()
            state["remote"]["pending_requests"]["late"] = {
                **state["remote"]["pending_requests"][request_id],
                "used_at": None,
                "created_at": 1,
                "expires_at": 2,
            }
            save_state(state)
        with self.state_env(self.laptop_state):
            publish_decision("late", "allow-session")
        with self.state_env(self.server_state):
            self.assertIsNone(request_remote_approval(request, wait_seconds=0, request_id="late"))
            self.assertEqual(len(load_state()["grants"]), 1)

    def test_pairing_code_can_approve_only_one_verified_backend(self) -> None:
        from worktreeguard_lite.remote_approval import accept_pairing_events
        from worktreeguard_lite.remote_pairing import connect_pair_code, create_pair_offer, identity
        from worktreeguard_lite.storage import load_state

        with self.state_env(self.laptop_state):
            offer = create_pair_offer(relay="fake://relay")
            laptop = identity(load_state(), "laptop")
        with self.state_env(self.server_state):
            first = connect_pair_code(offer.pair_code)
        with self.state_env(self.other_server_state):
            second = connect_pair_code(offer.pair_code)
        with self.state_env(self.laptop_state):
            state = load_state()
            accept_pairing_events(state, laptop, 0)
            approved = load_state()["remote"]["approved_peers"]
        self.assertIn(first["backend_pubkey"], approved)
        self.assertNotIn(second["backend_pubkey"], approved)

    def test_daemon_start_status_stop_clears_running_state(self) -> None:
        start = self.run_wtg("daemon", "server", "start", "--timeout", "30", state=self.server_state)
        self.assertEqual(start.returncode, 0, start.stderr)
        try:
            started = json.loads(start.stdout)
            self.assertTrue(started["running"])
            self.assertTrue(started["pid"])

            status = self.run_wtg("daemon", "server", "status", state=self.server_state)
            self.assertEqual(status.returncode, 0, status.stderr)
            payload = json.loads(status.stdout)
            self.assertTrue(payload["running"])
            self.assertEqual(payload["pid"], started["pid"])
        finally:
            stop = self.run_wtg("daemon", "server", "stop", state=self.server_state)
        self.assertEqual(stop.returncode, 0, stop.stderr)
        stopped = json.loads(stop.stdout)
        self.assertFalse(stopped["running"])

        status = self.run_wtg("daemon", "server", "status", state=self.server_state)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertFalse(json.loads(status.stdout)["running"])

    def append_event(self, event: dict[str, object]) -> None:
        record = dict(event)
        record.pop("_secret", None)
        record["relay"] = "fake://relay"
        with self.relay.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")


def first_request_id() -> str:
    events = [
        json.loads(line)
        for line in Path(os.environ["WTG_FAKE_RELAY_FILE"]).read_text(encoding="utf-8").splitlines()
    ]
    requests = [event for event in events if event["kind"] == 9]
    return requests[0]["id"]


if __name__ == "__main__":
    unittest.main()

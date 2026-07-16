#!/usr/bin/env python3
"""Command implementations for remote TTS."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time

from tts_remote_daemon import process_events
from tts_pair_token import (
    PAIRING_KIND,
    PairTokenError,
    decode_pair_token,
    encode_pair_token,
    pairing_key,
)
from tts_remote_channel import channel_parts
from tts_remote_config import remote_config, save_remote_config
from tts_remote_groups import reconcile_paired_channels, request_group_creation, wait_for_group_admin
from tts_remote_profile import profile_refresh_interval, publish_backend_profile, refresh_peer_profiles
from tts_remote_signing import signed_event
from tts_remote_state import (
    ensure_backend,
    ensure_laptop_identity,
    error,
    peers,
    read_json,
    remote_dir,
    save_peers,
    upsert_peer,
    write_json,
)
from tts_remote_transport import transport


SCRIPT_DIR = Path(__file__).resolve().parent


def emit(value: object) -> int:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def fail(code: str, message: str, guidance: str | None = None, exit_code: int = 1) -> int:
    print(json.dumps(error(code, message, guidance), ensure_ascii=False, sort_keys=True), file=sys.stderr)
    return exit_code


def pair_offer(args) -> int:
    laptop = ensure_laptop_identity()
    current = remote_config()
    relay = str(args.relay or current["relay"])
    channel = str(args.channel or current["channel"])
    save_remote_config(relay, channel)
    code = {
        "peer": laptop["pubkey"],
        "secret": secrets.token_urlsafe(32),
        "relay": relay,
        "channel": channel,
    }
    token = encode_pair_token(code)
    offer_id = pairing_key(code["secret"])
    channel_relay, group_id = channel_parts(channel)
    nip29 = request_group_creation(channel_relay, group_id, str(laptop["nsec"]))
    wait_for_group_admin(channel_relay, group_id, str(laptop["pubkey"]))
    write_json(
        remote_dir() / "pairings" / f"{offer_id}.json",
        {"code": code, "status": "offered", "nip29_group": nip29},
    )
    return emit({
        "status": "offered",
        "pair_code": token,
        "next_steps": [
            "Send this pairing code to the agent host.",
            "On the agent host, run the TTS pair connect command with the code.",
        ],
    })


def pair_connect(args) -> int:
    try:
        code = decode_pair_token(args.code)
    except PairTokenError as error:
        return fail("invalid_pair_code", str(error), "Ask the receiving device for a fresh pairing code.")
    code_id = pairing_key(code["secret"])
    used_path = remote_dir() / "used-pairings.json"
    used = read_json(used_path, [])
    used_ids = set(used if isinstance(used, list) else [])
    if code_id in used_ids:
        return fail("pair_code_used", "pair code has already been used", "Ask the receiving device for a fresh pairing code.")
    backend = ensure_backend()
    tx = transport(str(code["relay"]))
    publish_backend_profile(backend, str(code["relay"]))
    def publish_pairing_event() -> None:
        event = signed_event(
            kind=PAIRING_KIND,
            content=str(code["secret"]),
            tags=[["p", str(code["peer"])]],
            nsec=str(backend["nsec"]),
            relay=str(code["relay"]),
        )
        tx.publish(event)

    publish_pairing_event()
    channel_relay, group_id = channel_parts(str(code["channel"]))
    wait_for_group_admin(
        channel_relay,
        group_id,
        str(backend["pubkey"]),
        on_wait=publish_pairing_event,
    )
    peer = upsert_peer({
        "id": str(code["peer"]),
        "pubkey": str(code["peer"]),
        "relay": str(code["relay"]),
        "channel": str(code["channel"]),
        "product": "tts",
        "approved": True,
        "created_at": int(time.time()),
    })
    used_ids.add(code_id)
    write_json(used_path, sorted(used_ids))
    return emit({"status": "connected", "peer": peer, "backend_pubkey": backend["pubkey"]})


def pair_list(_args) -> int:
    return emit({"peers": peers()})


def pair_status(_args) -> int:
    backend = ensure_backend()
    active = [peer for peer in peers() if peer.get("approved") and not peer.get("revoked_at")]
    return emit({"paired": bool(active), "backend_pubkey": backend["pubkey"], "peers": active})


def pair_revoke(args) -> int:
    changed = False
    values = []
    for peer in peers():
        if peer.get("id") == args.peer or peer.get("pubkey") == args.peer:
            peer["approved"] = False
            peer["revoked_at"] = int(time.time())
            changed = True
        values.append(peer)
    save_peers(values)
    if not changed:
        return fail("peer_not_found", f"paired peer not found: {args.peer}", exit_code=2)
    return emit({"status": "revoked", "peer": args.peer})


def daemon_status(_args) -> int:
    state = read_json(remote_dir() / "daemon.json", {})
    running = bool(isinstance(state, dict) and state.get("running") and pid_alive(state.get("pid")))
    if isinstance(state, dict) and state.get("running") and not running:
        state = {**state, "running": False, "stopped_at": int(time.time())}
        write_json(remote_dir() / "daemon.json", state)
    return emit({"running": running, "state": state if isinstance(state, dict) else {}})


def daemon_start(args) -> int:
    lock_path = remote_dir() / "daemon-start.lock"
    with lock_path.open("a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        existing = read_json(remote_dir() / "daemon.json", {})
        if isinstance(existing, dict) and pid_alive(existing.get("pid")):
            pid = int(existing["pid"])
            status = "already_running"
            log = remote_dir() / "daemon.log"
        elif args.dry_run:
            return emit({"status": "started", "dry_run": True})
        else:
            log = remote_dir() / "daemon.log"
            with log.open("a", encoding="utf-8") as handle:
                process = subprocess.Popen(
                    [str(SCRIPT_DIR / "tts"), "daemon", "run"],
                    cwd=Path.home(),
                    stdin=subprocess.DEVNULL,
                    stdout=handle,
                    stderr=handle,
                    close_fds=True,
                    start_new_session=True,
                )
            pid = process.pid
            status = "started"
            write_json(
                remote_dir() / "daemon.json",
                {"running": True, "started_at": int(time.time()), "pid": pid},
            )
    return emit({"status": status, "pid": pid, "log": str(log), "menu_bar": start_menu_bar()})


def start_menu_bar() -> str:
    override = os.environ.get("TTS_REMOTE_MENU_COMMAND")
    disabled = os.environ.get("TTS_REMOTE_NO_MENU", "").lower() in {"1", "true", "yes"}
    if disabled or (sys.platform != "darwin" and not override):
        return "not_requested"
    command = override or str(SCRIPT_DIR / "tts-menu")
    try:
        completed = subprocess.run(
            [command, "start"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=180,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "failed"
    return "started" if completed.returncode == 0 else "failed"


def daemon_stop(_args) -> int:
    state = read_json(remote_dir() / "daemon.json", {})
    pid = state.get("pid") if isinstance(state, dict) else None
    if isinstance(pid, int) and pid != os.getpid():
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        wait_for_exit(pid)
    write_json(remote_dir() / "daemon.json", {"running": False, "stopped_at": int(time.time())})
    return emit({"status": "stopped"})


def pid_alive(pid: object) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def wait_for_exit(pid: int, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            return
        time.sleep(0.05)


def daemon_run(args) -> int:
    backend = ensure_laptop_identity()
    write_json(remote_dir() / "daemon.json", {"running": True, "pid": os.getpid(), "started_at": int(time.time())})
    processed = 0
    deadline = time.monotonic() + args.wait_seconds if args.wait_seconds is not None else None
    next_profile_refresh = 0.0
    next_channel_reconcile = 0.0
    try:
        while True:
            if time.monotonic() >= next_channel_reconcile:
                try:
                    reconcile_paired_channels(backend, peers())
                except RuntimeError:
                    next_channel_reconcile = time.monotonic() + 5
                else:
                    next_channel_reconcile = time.monotonic() + channel_reconcile_interval()
            if time.monotonic() >= next_profile_refresh:
                refresh_peer_profiles()
                next_profile_refresh = time.monotonic() + profile_refresh_interval()
            processed += process_events(args, backend)
            if args.once or (deadline is not None and time.monotonic() >= deadline):
                break
            time.sleep(0.25)
        return emit({"status": "idle", "processed": min(processed, args.max_events)})
    finally:
        write_json(remote_dir() / "daemon.json", {"running": False, "pid": os.getpid(), "stopped_at": int(time.time())})


def channel_reconcile_interval() -> float:
    try:
        return max(5.0, float(os.environ.get("TTS_CHANNEL_RECONCILE_SECONDS", "60")))
    except ValueError:
        return 60.0

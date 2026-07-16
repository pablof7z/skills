#!/usr/bin/env python3
"""Command implementations for remote TTS."""

from __future__ import annotations

import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import uuid

from tts_remote_daemon import process_events
from tts_remote_signing import public_key, signed_event
from tts_remote_state import active_peer, ensure_backend, ensure_laptop_identity, error, peers, remote_dir, save_peers, upsert_peer, write_json, read_json
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
    pairing_id = secrets.token_hex(16)
    expires_at = int(time.time()) + args.ttl
    code = {
        "version": 1,
        "product": "tts",
        "relay": args.relay,
        "laptop_pubkey": laptop["pubkey"],
        "pairing_id": pairing_id,
        "expires_at": expires_at,
        "secret": secrets.token_urlsafe(32),
    }
    write_json(remote_dir() / "pairings" / f"{pairing_id}.json", {"code": code, "status": "offered"})
    return emit({
        "status": "offered",
        "pair_code": code,
        "next_steps": [
            "Send this pairing code to the agent host.",
            "On the agent host, run the TTS pair connect command with the code.",
        ],
    })


def pair_connect(args) -> int:
    try:
        code = json.loads(args.code)
    except ValueError:
        return fail("invalid_pair_code", "pair code must be JSON")
    required = {"version", "product", "relay", "laptop_pubkey", "pairing_id", "expires_at", "secret"}
    if not isinstance(code, dict) or required - set(code) or code.get("product") != "tts":
        return fail("invalid_pair_code", "pair code is not a TTS pairing code")
    if int(code["expires_at"]) < int(time.time()):
        return fail("expired_pair_code", "pair code has expired", "Ask the laptop user for a fresh pairing code.")
    used_path = remote_dir() / "used-pairings.json"
    used = read_json(used_path, [])
    used_ids = set(used if isinstance(used, list) else [])
    if str(code["pairing_id"]) in used_ids:
        return fail("pair_code_used", "pair code has already been used", "Ask the laptop user for a fresh pairing code.")
    backend = ensure_backend()
    tx = transport(str(code["relay"]))
    profile = signed_event(
        kind=0,
        content=json.dumps({"name": f"{backend['hostname']} tts daemon", "product": "tts"}),
        tags=[["product", "tts"]],
        nsec=str(backend["nsec"]),
        relay=str(code["relay"]),
    )
    tx.publish(profile)
    event = signed_event(
        kind=24,
        content=str(code["secret"]),
        tags=[["p", str(code["laptop_pubkey"])], ["pairing", str(code["pairing_id"])], ["product", "tts"], ["version", "1"], ["expires", str(code["expires_at"])]],
        nsec=str(backend["nsec"]),
        relay=str(code["relay"]),
    )
    tx.publish(event)
    peer = upsert_peer({
        "id": str(code["laptop_pubkey"]),
        "pubkey": str(code["laptop_pubkey"]),
        "relay": str(code["relay"]),
        "pairing_id": str(code["pairing_id"]),
        "product": "tts",
        "approved": True,
        "created_at": int(time.time()),
    })
    used_ids.add(str(code["pairing_id"]))
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


def remote_speak(args) -> int:
    backend = ensure_backend()
    peer = active_peer(args.peer)
    if not peer:
        return fail("not_paired", "no approved TTS laptop pairing found", "Run tts pair offer on the laptop, then tts pair connect on this host.")
    signer_nsec = os.environ.get("AGENT_NSEC") or str(backend["nsec"])
    signer_source = "AGENT_NSEC" if os.environ.get("AGENT_NSEC") else "backend"
    signer_pubkey = public_key(signer_nsec)
    attachments = [{"label": label, "path": path} for label, path in zip(args.attach[0::2], args.attach[1::2])]
    request_id = str(uuid.uuid4())
    inner_content = {
        "version": 1,
        "product": "tts",
        "request_id": request_id,
        "message": args.message,
        "subject": args.subject,
        "agent_name": args.agent_name,
        "attachments": attachments,
        "backend": {"pubkey": backend["pubkey"]},
    }
    inner_event = signed_event(
        kind=9,
        content=json.dumps(inner_content, ensure_ascii=False, sort_keys=True),
        tags=[["p", str(peer["pubkey"])], ["h", "tts"], ["product", "tts"], ["request", request_id], ["reply", str(backend["pubkey"])]],
        nsec=signer_nsec,
        relay=str(peer.get("relay") or ""),
    )
    outer_content = {
        **inner_content,
        "inner_event": inner_event,
        "signer": {"source": signer_source, "pubkey": signer_pubkey},
    }
    event = signed_event(
        kind=9,
        content=json.dumps(outer_content, ensure_ascii=False, sort_keys=True),
        tags=[["p", str(peer["pubkey"])], ["h", "tts"], ["product", "tts"], ["request", request_id], ["reply", str(backend["pubkey"])]],
        nsec=str(backend["nsec"]),
        relay=str(peer.get("relay") or ""),
    )
    transport(str(peer.get("relay") or "")).publish(event)
    return emit({"status": "sent", "request_id": request_id, "event_id": event["id"], "peer": peer["pubkey"]})


def daemon_status(_args) -> int:
    state = read_json(remote_dir() / "daemon.json", {})
    running = bool(isinstance(state, dict) and state.get("running") and pid_alive(state.get("pid")))
    if isinstance(state, dict) and state.get("running") and not running:
        state = {**state, "running": False, "stopped_at": int(time.time())}
        write_json(remote_dir() / "daemon.json", state)
    return emit({"running": running, "state": state if isinstance(state, dict) else {}})


def daemon_start(args) -> int:
    state = {"running": True, "started_at": int(time.time()), "pid": os.getpid() if args.dry_run else None}
    write_json(remote_dir() / "daemon.json", state)
    if args.dry_run:
        return emit({"status": "started", "dry_run": True})
    log = remote_dir() / "daemon.log"
    with log.open("a", encoding="utf-8") as handle:
        process = subprocess.Popen([str(SCRIPT_DIR / "tts"), "daemon", "run", "--wait-seconds", "31536000"], stdout=handle, stderr=handle)
    state["pid"] = process.pid
    write_json(remote_dir() / "daemon.json", state)
    return emit({"status": "started", "pid": process.pid, "log": str(log)})


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
    deadline = time.monotonic() + args.wait_seconds
    try:
        while True:
            processed += process_events(args, backend)
            if args.once or processed >= args.max_events or time.monotonic() >= deadline:
                break
            time.sleep(0.25)
        return emit({"status": "idle", "processed": min(processed, args.max_events)})
    finally:
        write_json(remote_dir() / "daemon.json", {"running": False, "pid": os.getpid(), "stopped_at": int(time.time())})

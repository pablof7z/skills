#!/usr/bin/env python3
"""Command implementations for remote TTS."""

from __future__ import annotations

import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time
import uuid

from tts_remote_state import active_peer, ensure_backend, error, peers, remote_dir, save_peers, tts_state_dir, upsert_peer, write_json, read_json
from tts_remote_transport import signed_event, transport


SCRIPT_DIR = Path(__file__).resolve().parent


def emit(value: object) -> int:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def fail(code: str, message: str, guidance: str | None = None, exit_code: int = 1) -> int:
    print(json.dumps(error(code, message, guidance), ensure_ascii=False, sort_keys=True), file=sys.stderr)
    return exit_code


def tags_include(tags: object, name: str, value: str | None = None) -> bool:
    if not isinstance(tags, list):
        return False
    for tag in tags:
        if isinstance(tag, list) and tag and tag[0] == name and (value is None or tag[1:2] == [value]):
            return True
    return False


def pair_offer(args) -> int:
    backend = ensure_backend()
    pairing_id = secrets.token_hex(16)
    expires_at = int(time.time()) + args.ttl
    code = {
        "version": 1,
        "product": "tts",
        "relay": args.relay,
        "laptop_pubkey": args.laptop_pubkey or backend["pubkey"],
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
        tags=[["p", str(code["laptop_pubkey"])], ["pairing", str(code["pairing_id"])], ["product", "tts"]],
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
    attachments = [{"label": label, "path": path} for label, path in zip(args.attach[0::2], args.attach[1::2])]
    request_id = str(uuid.uuid4())
    content = {
        "version": 1,
        "product": "tts",
        "request_id": request_id,
        "message": args.message,
        "subject": args.subject,
        "agent_name": args.agent_name,
        "attachments": attachments,
        "backend": {"pubkey": backend["pubkey"]},
        "signer": {"source": signer_source, "nsec": signer_nsec},
    }
    event = signed_event(
        kind=9,
        content=json.dumps(content, ensure_ascii=False, sort_keys=True),
        tags=[["p", str(peer["pubkey"])], ["h", "tts"], ["product", "tts"], ["request", request_id], ["reply", str(backend["pubkey"])]],
        nsec=signer_nsec,
        relay=str(peer.get("relay") or ""),
    )
    transport(str(peer.get("relay") or "")).publish(event)
    return emit({"status": "sent", "request_id": request_id, "event_id": event["id"], "peer": peer["pubkey"]})


def daemon_status(_args) -> int:
    state = read_json(remote_dir() / "daemon.json", {})
    running = bool(isinstance(state, dict) and state.get("running"))
    return emit({"running": running, "state": state if isinstance(state, dict) else {}})


def daemon_start(args) -> int:
    state = {"running": True, "started_at": int(time.time()), "pid": os.getpid() if args.dry_run else None}
    write_json(remote_dir() / "daemon.json", state)
    if args.dry_run:
        return emit({"status": "started", "dry_run": True})
    log = remote_dir() / "daemon.log"
    with log.open("a", encoding="utf-8") as handle:
        process = subprocess.Popen([str(SCRIPT_DIR / "tts"), "daemon", "run"], stdout=handle, stderr=handle)
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
    write_json(remote_dir() / "daemon.json", {"running": False, "stopped_at": int(time.time())})
    return emit({"status": "stopped"})


def daemon_run(args) -> int:
    backend = ensure_backend()
    write_json(remote_dir() / "daemon.json", {"running": True, "pid": os.getpid(), "started_at": int(time.time())})
    processed = 0
    deadline = time.monotonic() + args.wait_seconds
    while True:
        processed += process_events(args, backend)
        if args.once or processed >= args.max_events:
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(0.25)
    return emit({"status": "idle", "processed": min(processed, args.max_events)})


def process_events(args, backend: dict[str, object]) -> int:
    tx = transport()
    seen_path = remote_dir() / "daemon-seen.json"
    seen = read_json(seen_path, [])
    seen_ids = set(seen if isinstance(seen, list) else [])
    count = 0
    for event in tx.events():
        event_id = str(event.get("id") or "")
        if not event_id or event_id in seen_ids or event.get("kind") != 9:
            continue
        if not tags_include(event.get("tags"), "p", str(backend["pubkey"])) and not tags_include(event.get("tags"), "p", socket.gethostname()) and not tags_include(event.get("tags"), "p", "laptop-daemon"):
            continue
        seen_ids.add(event_id)
        handle_request_event(event, backend)
        count += 1
        if count >= args.max_events:
            break
    write_json(seen_path, sorted(seen_ids))
    return count


def handle_request_event(event: dict[str, object], backend: dict[str, object]) -> None:
    try:
        content = json.loads(str(event.get("content") or "{}"))
    except ValueError:
        return publish_reply(event, backend, {"status": "rejected", "error": {"code": "invalid_request", "message": "request content is not JSON"}})
    attachments = content.get("attachments") if isinstance(content, dict) else []
    missing = [item for item in attachments or [] if not Path(str(item.get("path", ""))).is_file()]
    if missing:
        return publish_reply(event, backend, {
            "status": "rejected",
            "request_id": content.get("request_id"),
            "error": {
                "code": "remote_attachment_unavailable",
                "message": "one or more attachment paths are not available on this laptop",
                "guidance": "Send text only, or place the file on the paired laptop and retry with that local path.",
            },
        })
    try:
        result = materialize_request(content, event)
    except (subprocess.CalledProcessError, ValueError) as exc:
        return publish_reply(event, backend, {
            "status": "rejected",
            "request_id": content.get("request_id"),
            "error": {
                "code": "materialization_failed",
                "message": str(exc),
                "guidance": "Check the laptop TTS endpoint and retry after local TTS works on that laptop.",
            },
        })
    publish_reply(event, backend, {"status": "accepted", "request_id": content.get("request_id"), "item": result})


def materialize_request(content: dict[str, object], event: dict[str, object]) -> dict[str, object]:
    item_id = str(content.get("request_id") or uuid.uuid4())
    command = [
        str(SCRIPT_DIR / "tts"),
        "--agent-name", str(content.get("agent_name") or "remote"),
        "--subject", str(content.get("subject") or "Remote TTS request from paired host"),
        "--message", str(content.get("message") or ""),
    ]
    if os.environ.get("TTS_REMOTE_DAEMON_NO_PLAY"):
        command.append("--no-play")
    environment = os.environ.copy()
    environment["TTS_ITEM_ID"] = item_id
    completed = subprocess.run(command, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    output = json.loads(completed.stdout)
    item_path = tts_state_dir() / "items" / f"{item_id}.json"
    item = read_json(item_path, {})
    if isinstance(item, dict):
        item["remote_request"] = {"transport": "kind:9", "event_id": event.get("id"), "request_id": item_id}
        write_json(item_path, item)
    return output


def publish_reply(event: dict[str, object], backend: dict[str, object], content: dict[str, object]) -> None:
    relay = str(event.get("relay") or "")
    reply = signed_event(
        kind=9,
        content=json.dumps(content, ensure_ascii=False, sort_keys=True),
        tags=[["e", str(event.get("id"))], ["p", str(event.get("pubkey"))], ["h", "tts"], ["product", "tts"]],
        nsec=str(backend["nsec"]),
        relay=relay,
    )
    transport(relay).publish(reply)

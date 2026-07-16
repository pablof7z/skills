#!/usr/bin/env python3
"""Daemon event handling for remote TTS."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from tts_remote_signing import signed_event, verify_event
from tts_remote_state import active_peer, peers, read_json, remote_dir, tts_state_dir, upsert_peer, write_json
from tts_remote_transport import transport


SCRIPT_DIR = Path(__file__).resolve().parent


def tag_value(tags: object, name: str) -> str | None:
    if not isinstance(tags, list):
        return None
    for tag in tags:
        if isinstance(tag, list) and len(tag) >= 2 and tag[0] == name:
            return str(tag[1])
    return None


def tags_include(tags: object, name: str, value: str | None = None) -> bool:
    found = tag_value(tags, name)
    return found is not None and (value is None or found == value)


def process_events(args, backend: dict[str, object]) -> int:
    seen_path = remote_dir() / "daemon-seen.json"
    seen = read_json(seen_path, [])
    seen_ids = set(seen if isinstance(seen, list) else [])
    count = 0
    for event in events_from_relays():
        event_id = str(event.get("id") or "")
        if not event_id or event_id in seen_ids:
            continue
        handled = handle_pairing_event(event) or handle_request_event(event, backend)
        if handled:
            seen_ids.add(event_id)
            count += 1
        if count >= args.max_events:
            break
    write_json(seen_path, sorted(seen_ids))
    return count


def events_from_relays() -> list[dict[str, object]]:
    relays = {str(peer.get("relay")) for peer in peers() if peer.get("relay")}
    for offer_path in (remote_dir() / "pairings").glob("*.json"):
        offer = read_json(offer_path, {})
        if isinstance(offer, dict) and isinstance(offer.get("code"), dict):
            relays.add(str(offer["code"].get("relay") or ""))
    if not relays:
        relays.add("")
    events = []
    for relay in sorted(relays):
        events.extend(transport(relay).events())
    return events


def handle_pairing_event(event: dict[str, object]) -> bool:
    if event.get("kind") != 24 or not verify_event(event):
        return False
    pairing_id = tag_value(event.get("tags"), "pairing")
    if not pairing_id or not tags_include(event.get("tags"), "product", "tts"):
        return False
    offer_path = remote_dir() / "pairings" / f"{pairing_id}.json"
    offer = read_json(offer_path, {})
    if not isinstance(offer, dict) or offer.get("status") != "offered":
        return False
    code = offer.get("code")
    if not isinstance(code, dict):
        return False
    if not valid_pairing_event(event, code):
        return False
    peer = {
        "id": str(event.get("pubkey")),
        "pubkey": str(event.get("pubkey")),
        "relay": str(code.get("relay") or event.get("relay") or ""),
        "pairing_id": str(pairing_id),
        "product": "tts",
        "approved": True,
        "created_at": int(time.time()),
    }
    upsert_peer(peer)
    offer["status"] = "used"
    offer["used_at"] = int(time.time())
    offer["backend_pubkey"] = peer["pubkey"]
    write_json(offer_path, offer)
    return True


def valid_pairing_event(event: dict[str, object], code: dict[str, object]) -> bool:
    if int(code.get("expires_at", 0)) < int(time.time()):
        return False
    return (
        event.get("content") == code.get("secret")
        and tags_include(event.get("tags"), "p", str(code.get("laptop_pubkey")))
        and tags_include(event.get("tags"), "pairing", str(code.get("pairing_id")))
        and tags_include(event.get("tags"), "product", "tts")
        and tags_include(event.get("tags"), "version", str(code.get("version")))
        and tags_include(event.get("tags"), "expires", str(code.get("expires_at")))
    )


def handle_request_event(event: dict[str, object], backend: dict[str, object]) -> bool:
    if event.get("kind") != 9 or not verify_event(event):
        return False
    peer = active_peer(str(event.get("pubkey")))
    if not peer or not valid_request_tags(event, backend):
        return False
    content = request_content(event)
    if not content:
        publish_reply(event, backend, {"status": "rejected", "error": {"code": "invalid_request", "message": "request content is not JSON"}})
        return True
    if not valid_inner_request(content):
        publish_reply(event, backend, {"status": "rejected", "request_id": content.get("request_id"), "error": {"code": "invalid_signature", "message": "inner request signature is invalid"}})
        return True
    attachments = content.get("attachments") if isinstance(content, dict) else []
    missing = [item for item in attachments or [] if not Path(str(item.get("path", ""))).is_file()]
    if missing:
        publish_reply(event, backend, rejection(content, "remote_attachment_unavailable"))
        return True
    try:
        result = materialize_request(content, event)
    except (subprocess.CalledProcessError, ValueError) as exc:
        publish_reply(event, backend, materialization_error(content, exc))
        return True
    publish_reply(event, backend, {"status": "accepted", "request_id": content.get("request_id"), "item": result})
    return True


def valid_request_tags(event: dict[str, object], backend: dict[str, object]) -> bool:
    content = request_content(event)
    request_id = content.get("request_id") if isinstance(content, dict) else None
    return (
        tags_include(event.get("tags"), "p", str(backend["pubkey"]))
        and tags_include(event.get("tags"), "h", "tts")
        and tags_include(event.get("tags"), "product", "tts")
        and bool(request_id)
        and tags_include(event.get("tags"), "request", str(request_id))
    )


def request_content(event: dict[str, object]) -> dict[str, object]:
    try:
        outer = json.loads(str(event.get("content") or "{}"))
    except ValueError:
        return {}
    inner = outer.get("inner_event") if isinstance(outer, dict) else None
    if not isinstance(inner, dict):
        return outer if isinstance(outer, dict) else {}
    try:
        content = json.loads(str(inner.get("content") or "{}"))
    except ValueError:
        return {}
    if isinstance(content, dict):
        content["inner_event"] = inner
        content["signer"] = outer.get("signer")
    return content if isinstance(content, dict) else {}


def valid_inner_request(content: dict[str, object]) -> bool:
    inner = content.get("inner_event")
    return isinstance(inner, dict) and inner.get("kind") == 9 and verify_event(inner)


def rejection(content: dict[str, object], code: str) -> dict[str, object]:
    return {
        "status": "rejected",
        "request_id": content.get("request_id"),
        "error": {
            "code": code,
            "message": "one or more attachment paths are not available on this laptop",
            "guidance": "Send text only, or place the file on the paired laptop and retry with that local path.",
        },
    }


def materialization_error(content: dict[str, object], exc: Exception) -> dict[str, object]:
    return {
        "status": "rejected",
        "request_id": content.get("request_id"),
        "error": {
            "code": "materialization_failed",
            "message": str(exc),
            "guidance": "Check the laptop TTS endpoint and retry after local TTS works on that laptop.",
        },
    }


def materialize_request(content: dict[str, object], event: dict[str, object]) -> dict[str, object]:
    item_id = str(content.get("request_id") or uuid.uuid4())
    command = [str(SCRIPT_DIR / "tts"), "--agent-name", str(content.get("agent_name") or "remote"), "--subject", str(content.get("subject") or "Remote TTS request from paired host"), "--message", str(content.get("message") or "")]
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

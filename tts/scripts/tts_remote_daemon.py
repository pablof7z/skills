#!/usr/bin/env python3
"""Daemon event handling for remote TTS."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from tts_pair_token import PAIRING_KIND, pairing_key
from tts_remote_channel import channel_parts
from tts_remote_groups import request_group_admin, request_group_membership
from tts_remote_polling import events_for_laptop
from tts_remote_protocol import reply_tags, request_payload, tag_value
from tts_remote_signing import signed_event, verify_event
from tts_remote_state import active_peer, read_json, remote_dir, tts_state_dir, upsert_peer, write_json
from tts_remote_transport import transport


SCRIPT_DIR = Path(__file__).resolve().parent


def tags_include(tags: object, name: str, value: str | None = None) -> bool:
    found = tag_value({"tags": tags}, name)
    return found is not None and (value is None or found == value)


def process_events(args, backend: dict[str, object]) -> int:
    seen_path = remote_dir() / "daemon-seen.json"
    seen = read_json(seen_path, [])
    seen_ids = set(seen if isinstance(seen, list) else [])
    count = 0
    events = sorted(
        events_for_laptop(str(backend["pubkey"])),
        key=lambda event: 0 if event.get("kind") == PAIRING_KIND else 1,
    )
    for event in events:
        event_id = str(event.get("id") or "")
        if not event_id or event_id in seen_ids:
            continue
        handled = handle_pairing_event(event) or handle_request_event(event, backend)
        seen_ids.add(event_id)
        if handled:
            count += 1
        if count >= args.max_events:
            break
    write_json(seen_path, sorted(seen_ids))
    return count


def handle_pairing_event(event: dict[str, object]) -> bool:
    if event.get("kind") != PAIRING_KIND or not verify_event(event):
        return False
    secret = str(event.get("content") or "")
    if not secret:
        return False
    offer_path = remote_dir() / "pairings" / f"{pairing_key(secret)}.json"
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
        "channel": str(code.get("channel")),
        "product": "tts",
        "approved": True,
        "created_at": int(time.time()),
    }
    nsec = ensure_laptop_nsec()
    channel_relay, group_id = channel_parts(str(peer["channel"]), str(peer["relay"]))
    peer["nip29_membership"] = request_group_membership(
        channel_relay,
        group_id,
        nsec,
        str(peer["pubkey"]),
    )
    peer["nip29_admin"] = request_group_admin(
        channel_relay,
        group_id,
        nsec,
        str(peer["pubkey"]),
    )
    upsert_peer(peer)
    offer["status"] = "used"
    offer["used_at"] = int(time.time())
    offer["backend_pubkey"] = peer["pubkey"]
    write_json(offer_path, offer)
    return True


def valid_pairing_event(event: dict[str, object], code: dict[str, object]) -> bool:
    return (
        event.get("content") == code.get("secret")
        and event.get("tags") == [["p", str(code.get("peer"))]]
        and (not event.get("relay") or event.get("relay") == code.get("relay"))
    )


def handle_request_event(event: dict[str, object], backend: dict[str, object]) -> bool:
    if event.get("kind") != 9 or not verify_event(event):
        return False
    peer = active_peer(str(tag_value(event, "reply") or ""))
    if not peer or not valid_request_tags(event, backend, peer):
        return False
    channel = str(peer.get("channel") or peer.get("group_id") or "")
    relay, group_id = channel_parts(channel, str(peer.get("relay") or ""))
    try:
        members = transport(relay).group_members(group_id)
    except RuntimeError:
        return False
    if str(event.get("pubkey") or "") not in members:
        return False
    content = request_payload(event)
    if content is None:
        publish_reply(event, backend, "rejected", error_code="invalid_request")
        return True
    attachments = content["attachments"]
    if any(not Path(str(item["path"])).is_file() for item in attachments):
        publish_reply(
            event,
            backend,
            "rejected",
            error_code="remote_attachment_unavailable",
            guidance="Send text only, or place the file on the paired laptop and retry.",
        )
        return True
    try:
        materialize_request(content, event)
    except (subprocess.CalledProcessError, ValueError):
        publish_reply(
            event,
            backend,
            "rejected",
            error_code="materialization_failed",
            guidance="Check the laptop TTS endpoint and retry after local TTS works.",
        )
        return True
    publish_reply(event, backend, "accepted")
    return True


def valid_request_tags(
    event: dict[str, object],
    backend: dict[str, object],
    peer: dict[str, object],
) -> bool:
    request_id = tag_value(event, "request")
    return (
        tags_include(event.get("tags"), "p", str(backend["pubkey"]))
        and tags_include(
            event.get("tags"),
            "h",
            channel_parts(
                str(peer.get("channel") or peer.get("group_id") or ""),
                str(peer.get("relay") or ""),
            )[1],
        )
        and tags_include(event.get("tags"), "product", "tts")
        and tags_include(event.get("tags"), "reply", str(peer.get("pubkey")))
        and bool(request_id)
    )


def materialize_request(content: dict[str, object], event: dict[str, object]) -> dict[str, object]:
    item_id = str(content.get("request_id") or uuid.uuid4())
    command = [str(SCRIPT_DIR / "tts"), "--agent-name", str(content.get("agent_name") or "remote"), "--subject", str(content.get("subject") or "Remote TTS request from paired host"), "--message", str(content.get("message") or "")]
    for attachment in content.get("attachments") or []:
        path = Path(str(attachment.get("path") or "")).resolve()
        label = str(attachment.get("label") or path.name)
        command.extend(["--attach", label, str(path)])
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


def publish_reply(
    event: dict[str, object],
    backend: dict[str, object],
    status: str,
    *,
    error_code: str | None = None,
    guidance: str | None = None,
) -> None:
    relay = str(event.get("relay") or "")
    reply = signed_event(
        kind=9,
        content=str(event.get("content") or ""),
        tags=reply_tags(event, status, error_code=error_code, guidance=guidance),
        nsec=str(backend["nsec"]),
        relay=relay,
    )
    transport(relay).publish(reply)


def ensure_laptop_nsec() -> str:
    laptop = read_json(remote_dir() / "laptop.json", {})
    if not isinstance(laptop, dict) or not laptop.get("nsec"):
        raise RuntimeError("laptop signer is unavailable")
    return str(laptop["nsec"])

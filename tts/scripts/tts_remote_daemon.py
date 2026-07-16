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
from tts_remote_signing import signed_event, verify_event
from tts_remote_state import active_peer, read_json, remote_dir, tts_state_dir, upsert_peer, write_json
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
    peer = active_peer(str(tag_value(event.get("tags"), "reply") or ""))
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
    content = request_content(event)
    if not content:
        publish_reply(event, backend, {"status": "rejected", "error": {"code": "invalid_request", "message": "request content is not JSON"}})
        return True
    if not valid_direct_request(content, event, peer):
        return False
    attachments = normalized_attachments(content.get("attachments"))
    if attachments is None:
        publish_reply(event, backend, rejection(content, "invalid_remote_attachment"))
        return True
    if any(not Path(str(item["path"])).is_file() for item in attachments):
        publish_reply(event, backend, rejection(content, "remote_attachment_unavailable"))
        return True
    content["attachments"] = attachments
    try:
        result = materialize_request(content, event)
    except (subprocess.CalledProcessError, ValueError) as exc:
        publish_reply(event, backend, materialization_error(content, exc))
        return True
    publish_reply(event, backend, {"status": "accepted", "request_id": content.get("request_id"), "item": result})
    return True


def valid_request_tags(
    event: dict[str, object],
    backend: dict[str, object],
    peer: dict[str, object],
) -> bool:
    content = request_content(event)
    request_id = content.get("request_id") if isinstance(content, dict) else None
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
        and tags_include(event.get("tags"), "request", str(request_id))
    )


def request_content(event: dict[str, object]) -> dict[str, object]:
    try:
        content = json.loads(str(event.get("content") or "{}"))
    except ValueError:
        return {}
    return content if isinstance(content, dict) else {}


def valid_direct_request(
    content: dict[str, object],
    event: dict[str, object],
    peer: dict[str, object],
) -> bool:
    backend = content.get("backend")
    request_id = content.get("request_id")
    if not isinstance(backend, dict) or not request_id:
        return False
    return (
        content.get("product") == "tts"
        and backend.get("pubkey") == peer.get("pubkey")
        and tags_include(event.get("tags"), "request", str(request_id))
    )


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


def normalized_attachments(value: object) -> list[dict[str, str]] | None:
    if value is None:
        return []
    if not isinstance(value, list):
        return None
    result = []
    for item in value:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            return None
        path = item["path"].strip()
        label = item.get("label")
        if not path or (label is not None and not isinstance(label, str)):
            return None
        result.append({"path": path, "label": str(label or Path(path).name)})
    return result


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


def publish_reply(event: dict[str, object], backend: dict[str, object], content: dict[str, object]) -> None:
    relay = str(event.get("relay") or "")
    reply_target = str(tag_value(event.get("tags"), "reply") or event.get("pubkey") or "")
    reply = signed_event(
        kind=9,
        content=json.dumps(content, ensure_ascii=False, sort_keys=True),
        tags=[["e", str(event.get("id"))], ["p", reply_target], ["h", str(tag_value(event.get("tags"), "h"))], ["product", "tts"]],
        nsec=str(backend["nsec"]),
        relay=relay,
    )
    transport(relay).publish(reply)


def ensure_laptop_nsec() -> str:
    laptop = read_json(remote_dir() / "laptop.json", {})
    if not isinstance(laptop, dict) or not laptop.get("nsec"):
        raise RuntimeError("laptop signer is unavailable")
    return str(laptop["nsec"])

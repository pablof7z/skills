#!/usr/bin/env python3
"""Daemon event handling for remote TTS."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time

from tts_pair_token import PAIRING_KIND, pairing_key
from tts_remote_channel import channel_parts
from tts_remote_groups import request_group_admin, request_group_membership
from tts_remote_ask import answers_from_result
from tts_remote_polling import events_for_laptop
from tts_remote_profile import profile_name
from tts_remote_protocol import render_reply_content, reply_tags, request_payload, tag_value
from tts_remote_signing import signed_event, verify_event
from tts_remote_state import peers, read_json, remote_dir, tts_state_dir, upsert_peer, write_json
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
    try:
        name = profile_name(str(peer["pubkey"]), str(peer["relay"]))
    except (OSError, RuntimeError):
        name = None
    if name:
        peer["name"] = name
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
    peer = request_peer(event)
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
        result = materialize_request(content, event)
    except subprocess.CalledProcessError as error:
        detail = safe_materialization_detail(error.stderr)
        print(f"TTS materialization failed for {event.get('id')}: {detail}", file=sys.stderr)
        publish_reply(
            event,
            backend,
            "rejected",
            error_code="materialization_failed",
            guidance=materialization_guidance(detail),
        )
        return True
    except ValueError as error:
        print(
            f"TTS materialization returned invalid JSON for {event.get('id')}: {error}",
            file=sys.stderr,
        )
        publish_reply(
            event,
            backend,
            "rejected",
            error_code="materialization_failed",
            guidance="The laptop TTS command returned an invalid response. Check its daemon log and retry.",
        )
        return True
    if content.get("ask"):
        publish_reply(
            event,
            backend,
            str(result.get("status") or "rejected"),
            answers=answers_from_result(result, event),
        )
    else:
        publish_reply(event, backend, "accepted")
    return True


def safe_materialization_detail(stderr: str | None) -> str:
    lines = [
        line.strip()
        for line in (stderr or "").splitlines()
        if line.strip().startswith(("Error:", "Warning:"))
    ]
    return " | ".join(lines[-3:])[:1000] or "local TTS command exited without a diagnostic"


def materialization_guidance(detail: str) -> str:
    if detail == "local TTS command exited without a diagnostic":
        return "The laptop TTS command failed before queueing. Check its daemon log and retry."
    return f"Laptop TTS: {detail}"


def environment_enabled(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def valid_request_tags(
    event: dict[str, object],
    backend: dict[str, object],
    peer: dict[str, object],
) -> bool:
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
    )


def request_peer(event: dict[str, object]) -> dict[str, object] | None:
    event_group = tag_value(event, "h")
    event_relay = str(event.get("relay") or "")
    for peer in peers():
        channel = str(peer.get("channel") or peer.get("group_id") or "")
        relay, group_id = channel_parts(channel, str(peer.get("relay") or ""))
        if (
            peer.get("approved")
            and not peer.get("revoked_at")
            and group_id == event_group
            and (not event_relay or relay == event_relay)
        ):
            return peer
    return None


def materialize_request(content: dict[str, object], event: dict[str, object]) -> dict[str, object]:
    item_id = str(event.get("id") or "")
    command = [str(SCRIPT_DIR / "tts"), "--agent-name", str(content.get("agent_name") or "remote"), "--subject", str(content.get("subject") or "Remote TTS request from paired host"), "--message", str(content.get("message") or "")]
    for attachment in content.get("attachments") or []:
        path = Path(str(attachment.get("path") or "")).resolve()
        label = str(attachment.get("label") or path.name)
        command.extend(["--attach", label, str(path)])
    if content.get("ask"):
        command.extend(["--wait", str(content["wait"]), "--ask", str(content["ask"])])
    if environment_enabled("TTS_REMOTE_DAEMON_NO_PLAY") and not content.get("ask"):
        command.append("--no-play")
    environment = os.environ.copy()
    environment["TTS_ITEM_ID"] = item_id
    environment["TTS_FORCE_LOCAL"] = "1"
    environment["TTS_REMOTE_MATERIALIZATION"] = "1"
    completed = subprocess.run(command, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    output = json.loads(completed.stdout)
    item_path = tts_state_dir() / "items" / f"{item_id}.json"
    item = read_json(item_path, {})
    if isinstance(item, dict):
        item["remote_request"] = {"transport": "kind:9", "event_id": event.get("id")}
        write_json(item_path, item)
    return output


def publish_reply(
    event: dict[str, object],
    backend: dict[str, object],
    status: str,
    *,
    error_code: str | None = None,
    guidance: str | None = None,
    answers: list[tuple[str, list[str]]] | None = None,
) -> None:
    relay = str(event.get("relay") or "")
    tags = reply_tags(event, answers=answers, error_code=error_code)
    if error_code:
        content = f"# TTS request failed\n\n{guidance or error_code.replace('_', ' ')}"
    elif status == "accepted":
        content = f"# TTS request accepted\n\n{tag_value(event, 'title') or event.get('content') or ''}"
    else:
        content = render_reply_content(event, tags)
    reply = signed_event(
        kind=9,
        content=content,
        tags=tags,
        nsec=str(backend["nsec"]),
        relay=relay,
    )
    transport(relay).publish(reply)


def ensure_laptop_nsec() -> str:
    laptop = read_json(remote_dir() / "laptop.json", {})
    if not isinstance(laptop, dict) or not laptop.get("nsec"):
        raise RuntimeError("laptop signer is unavailable")
    return str(laptop["nsec"])

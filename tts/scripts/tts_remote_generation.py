#!/usr/bin/env python3
"""Paired generation-only TTS requests and Blossom result replies."""

from __future__ import annotations

import json
import os
import re
import sys
import time
from urllib.parse import urlparse

from tts_remote_channel import channel_parts
from tts_remote_groups import ensure_group_member
from tts_remote_profile import publish_endpoint_profile
from tts_remote_protocol import request_tags, tag_value
from tts_remote_signing import public_key, signed_event, verify_event
from tts_remote_state import active_peer, ensure_backend, error
from tts_remote_transport import transport


def remote_generate(args) -> int:
    backend = ensure_backend()
    peer = active_peer(args.peer)
    if not peer:
        return fail(
            "not_paired",
            "no approved TTS laptop pairing found",
            "Pair this MCP host with the computer that runs TTS, then retry.",
        )
    signer_nsec = os.environ.get("AGENT_NSEC") or str(backend["nsec"])
    signer_pubkey = public_key(signer_nsec)
    pairing_relay = str(peer.get("relay") or "")
    channel = str(peer.get("channel") or peer.get("group_id") or "")
    relay, group_id = channel_parts(channel, pairing_relay)
    publish_endpoint_profile(backend, pairing_relay)
    if os.environ.get("AGENT_NSEC"):
        ensure_group_member(relay, group_id, str(backend["nsec"]), signer_pubkey)
    tags = request_tags(
        peer_pubkey=str(peer["pubkey"]),
        group_id=group_id,
        title=args.subject,
        agent_name=args.agent_name,
        message=args.message,
        attachments=[],
    )
    tags.append(["action", "generate"])
    event = signed_event(
        kind=9,
        content=args.message,
        tags=tags,
        nsec=signer_nsec,
        relay=relay,
    )
    transport(relay).publish(event)
    result = wait_for_generation(event, relay=relay, timeout=str(args.wait))
    if result.get("status") != "uploaded":
        print(json.dumps(result, sort_keys=True), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def wait_for_generation(
    request_event: dict[str, object],
    *,
    relay: str,
    timeout: str,
) -> dict[str, object]:
    request_id = str(request_event.get("id") or "")
    requester = str(request_event.get("pubkey") or "")
    group_id = tag_value(request_event, "h") or ""
    seconds = generation_timeout(timeout)
    deadline = time.monotonic() + seconds
    since = max(0, int(request_event.get("created_at") or 0) - 1)
    while time.monotonic() < deadline:
        events = transport(relay).events(
            target_pubkey=requester,
            group_ids=[group_id],
            since=since,
            kinds=[9],
            referenced_event_id=request_id,
        )
        for event in events:
            if valid_generation_reply(event, request_event):
                return generation_result(event)
        time.sleep(min(0.5, max(0.0, deadline - time.monotonic())))
    return {
        "status": "pending",
        "event_id": request_id,
        "guidance": "The paired computer has not returned the generated MP3 yet.",
    }


def valid_generation_reply(
    event: dict[str, object],
    request_event: dict[str, object],
) -> bool:
    return (
        event.get("pubkey") == tag_value(request_event, "p")
        and tag_value(event, "e") == request_event.get("id")
        and tag_value(event, "p") == request_event.get("pubkey")
        and tag_value(event, "h") == tag_value(request_event, "h")
        and (tag_value(event, "status") == "uploaded" or tag_value(event, "error") is not None)
        and verify_event(event)
    )


def generation_result(event: dict[str, object]) -> dict[str, object]:
    error_code = tag_value(event, "error")
    if error_code:
        return {
            "status": "error",
            "error": {"code": error_code, "message": str(event.get("content") or error_code)},
        }
    url = tag_value(event, "url") or ""
    sha256 = tag_value(event, "x") or ""
    mime_type = tag_value(event, "m") or ""
    try:
        size = int(tag_value(event, "size") or "")
        uploaded = int(tag_value(event, "uploaded") or "")
    except ValueError as error:
        raise RuntimeError("paired TTS returned invalid Blossom metadata") from error
    if (
        urlparse(url).scheme != "https"
        or not re.fullmatch(r"[0-9a-f]{64}", sha256)
        or size <= 0
        or uploaded <= 0
        or mime_type != "audio/mpeg"
    ):
        raise RuntimeError("paired TTS returned an invalid Blossom descriptor")
    return {
        "status": "uploaded",
        "url": url,
        "sha256": sha256,
        "size": size,
        "type": mime_type,
        "uploaded": uploaded,
        "server": tag_value(event, "server"),
    }


def publish_generation_reply(
    request_event: dict[str, object],
    laptop: dict[str, object],
    descriptor: dict[str, object],
) -> None:
    tags = [
        ["e", str(request_event.get("id") or "")],
        ["p", str(request_event.get("pubkey") or "")],
        ["h", tag_value(request_event, "h") or ""],
        ["status", "uploaded"],
        ["url", str(descriptor["url"])],
        ["x", str(descriptor["sha256"])],
        ["size", str(descriptor["size"])],
        ["m", "audio/mpeg"],
        ["uploaded", str(descriptor["uploaded"])],
        ["server", str(descriptor["server"])],
    ]
    reply = signed_event(
        kind=9,
        content=f"# Generated TTS audio\n\n{descriptor['url']}",
        tags=tags,
        nsec=str(laptop["nsec"]),
        relay=str(request_event.get("relay") or ""),
    )
    transport(str(request_event.get("relay") or "")).publish(reply)


def generation_timeout(value: str) -> float:
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smh]?)", value.strip(), re.IGNORECASE)
    if not match or float(match.group(1)) <= 0:
        raise RuntimeError("generation wait must be a positive duration")
    seconds = float(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2).lower()]
    if seconds > 3600:
        raise RuntimeError("generation wait cannot exceed 1h")
    return seconds


def fail(code: str, message: str, guidance: str) -> int:
    print(json.dumps(error(code, message, guidance), sort_keys=True), file=sys.stderr)
    return 1

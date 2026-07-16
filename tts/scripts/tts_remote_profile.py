#!/usr/bin/env python3
"""Publish and resolve paired TTS endpoint hostname profiles."""

from __future__ import annotations

import json
import os
import socket
import time

from tts_remote_signing import signed_event, verify_event
from tts_remote_state import peers, read_json, remote_dir, save_peers, write_json
from tts_remote_transport import transport


PROFILE_KIND = 0


def publish_endpoint_profile(
    endpoint: dict[str, object],
    relay: str,
    *,
    force: bool = False,
) -> bool:
    name = clean_name(
        os.environ.get("TTS_REMOTE_HOSTNAME") or socket.gethostname() or endpoint.get("hostname")
    )
    if not relay or not name or not endpoint.get("nsec"):
        return False
    state_path = remote_dir() / "profile-publications.json"
    loaded = read_json(state_path, {})
    state = loaded if isinstance(loaded, dict) else {}
    existing = state.get(relay)
    if (
        not force
        and isinstance(existing, dict)
        and existing.get("name") == name
        and existing.get("pubkey") == endpoint.get("pubkey")
    ):
        return True
    try:
        event = signed_event(
            kind=PROFILE_KIND,
            content=json.dumps({"display_name": name, "name": name}, sort_keys=True, separators=(",", ":")),
            tags=[],
            nsec=str(endpoint["nsec"]),
            relay=relay,
        )
        transport(relay).publish(event)
    except (OSError, RuntimeError):
        return False
    state[relay] = {
        "name": name,
        "pubkey": endpoint.get("pubkey"),
        "event_id": event.get("id"),
        "published_at": int(time.time()),
    }
    write_json(state_path, state)
    return True


def refresh_peer_profiles() -> int:
    values = peers()
    changed = 0
    for peer in values:
        if not peer.get("approved") or peer.get("revoked_at"):
            continue
        try:
            name = profile_name(str(peer.get("pubkey") or ""), str(peer.get("relay") or ""))
        except (OSError, RuntimeError):
            continue
        if name and peer.get("name") != name:
            peer["name"] = name
            changed += 1
    if changed:
        save_peers(values)
    return changed


def profile_name(pubkey: str, relay: str) -> str | None:
    if not pubkey or not relay:
        return None
    events = transport(relay).events(author_pubkeys=[pubkey], kinds=[PROFILE_KIND])
    for event in sorted(events, key=event_timestamp, reverse=True):
        if event.get("pubkey") != pubkey or event.get("kind") != PROFILE_KIND or not verify_event(event):
            continue
        try:
            metadata = json.loads(str(event.get("content") or "{}"))
        except ValueError:
            continue
        if not isinstance(metadata, dict):
            continue
        name = clean_name(metadata.get("name") or metadata.get("display_name"))
        if name:
            return name
    return None


def clean_name(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    name = value.strip()
    if not name or len(name) > 80 or any(ord(character) < 32 for character in name):
        return None
    return name


def event_timestamp(event: dict[str, object]) -> int:
    try:
        return int(event.get("created_at") or 0)
    except (TypeError, ValueError):
        return 0


def profile_refresh_interval() -> float:
    try:
        return max(5.0, min(3600.0, float(os.environ.get("TTS_PROFILE_REFRESH_SECONDS", "30"))))
    except ValueError:
        return 30.0

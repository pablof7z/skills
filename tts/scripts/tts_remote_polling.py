#!/usr/bin/env python3
"""Targeted, cursor-backed relay polling for the laptop daemon."""

from __future__ import annotations

import os

from tts_pair_token import PAIRING_KIND
from tts_remote_channel import channel_parts
from tts_remote_config import remote_config
from tts_remote_state import peers, read_json, remote_dir, write_json
from tts_remote_transport import transport


def events_for_laptop(laptop_pubkey: str) -> list[dict[str, object]]:
    pairing_relays, request_groups = polling_coordinates()
    cursor_path = remote_dir() / "relay-cursors.json"
    loaded = read_json(cursor_path, {})
    cursors = loaded if isinstance(loaded, dict) else {}
    events: list[dict[str, object]] = []
    changed = False
    for relay in sorted(pairing_relays):
        tx = transport(relay)
        pairing_key = f"{relay}|pairing"
        pairing_since = cursor_value(cursors.get(pairing_key))
        pairing_events = tx.events(
            target_pubkey=laptop_pubkey,
            since=pairing_since,
            kinds=[PAIRING_KIND],
        )
        events.extend(pairing_events)
        newest_pairing = newest_timestamp(pairing_events, pairing_since)
        if newest_pairing and newest_pairing != pairing_since:
            cursors[pairing_key] = newest_pairing
            changed = True
    for relay, group_ids in sorted(request_groups.items()):
        request_key = f"{relay}|requests"
        request_since = cursor_value(cursors.get(request_key))
        request_events = transport(relay).events(
            target_pubkey=laptop_pubkey,
            group_ids=sorted(group_ids),
            since=request_since,
            kinds=[9],
        )
        events.extend(request_events)
        newest_request = newest_timestamp(request_events, request_since)
        if newest_request and newest_request != request_since:
            cursors[request_key] = newest_request
            changed = True
    if changed:
        write_json(cursor_path, cursors)
    return events


def polling_coordinates() -> tuple[set[str], dict[str, set[str]]]:
    pairing_relays: set[str] = set()
    request_groups: dict[str, set[str]] = {}
    records = [remote_config(), *peers()]
    for offer_path in (remote_dir() / "pairings").glob("*.json"):
        offer = read_json(offer_path, {})
        if isinstance(offer, dict) and isinstance(offer.get("code"), dict):
            records.append(offer["code"])
    for record in records:
        relay = str(record.get("relay") or "")
        channel = str(record.get("channel") or record.get("group_id") or "")
        if relay:
            pairing_relays.add(relay)
        if channel:
            channel_relay, group_id = channel_parts(channel, relay)
            request_groups.setdefault(channel_relay, set()).add(group_id)
    return pairing_relays, request_groups


def cursor_value(value: object) -> int | None:
    if not isinstance(value, int):
        return None
    # Relay cursors are advanced as soon as a batch is fetched, while an
    # individual request may still be awaiting local authorization or
    # materialization. Re-read a short overlap on the next poll so a brief
    # connectivity loss cannot turn that request into a permanent gap. The
    # daemon-seen ledger keeps the overlap idempotent.
    return max(0, int(value) - cursor_overlap_seconds())


def cursor_overlap_seconds() -> int:
    try:
        return max(1, min(300, int(os.environ.get("TTS_REMOTE_CURSOR_OVERLAP_SECONDS", "60"))))
    except ValueError:
        return 60


def newest_timestamp(events: list[dict[str, object]], since: int | None) -> int:
    return max((int(event.get("created_at") or 0) for event in events), default=since or 0)

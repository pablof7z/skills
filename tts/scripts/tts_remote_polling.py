#!/usr/bin/env python3
"""Targeted, cursor-backed relay polling for the laptop daemon."""

from __future__ import annotations

from tts_remote_state import peers, read_json, remote_dir, write_json
from tts_remote_transport import transport


def events_for_laptop(laptop_pubkey: str) -> list[dict[str, object]]:
    relay_groups = pairing_relay_groups()
    cursor_path = remote_dir() / "relay-cursors.json"
    loaded = read_json(cursor_path, {})
    cursors = loaded if isinstance(loaded, dict) else {}
    events: list[dict[str, object]] = []
    changed = False
    for relay, group_ids in sorted(relay_groups.items()):
        since = cursor_value(cursors.get(relay))
        fetched = transport(relay).events(
            target_pubkey=laptop_pubkey,
            group_ids=sorted(group_ids),
            since=since,
        )
        events.extend(fetched)
        newest = max((int(event.get("created_at") or 0) for event in fetched), default=since or 0)
        if newest and newest != since:
            cursors[relay] = newest
            changed = True
    if changed:
        write_json(cursor_path, cursors)
    return events


def pairing_relay_groups() -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    records = list(peers())
    for offer_path in (remote_dir() / "pairings").glob("*.json"):
        offer = read_json(offer_path, {})
        if isinstance(offer, dict) and isinstance(offer.get("code"), dict):
            records.append(offer["code"])
    for record in records:
        relay = str(record.get("relay") or "")
        group_id = str(record.get("group_id") or "")
        if relay and group_id:
            result.setdefault(relay, set()).add(group_id)
    return result


def cursor_value(value: object) -> int | None:
    return max(0, int(value)) if isinstance(value, int) else None

#!/usr/bin/env python3
"""Canonical Nostr event filtering helpers for remote TTS."""

from __future__ import annotations

import json


NOSTR_EVENT_FIELDS = frozenset({"id", "pubkey", "created_at", "kind", "tags", "content", "sig"})


def parse_events(raw: str) -> list[dict[str, object]]:
    stripped = raw.strip()
    if not stripped:
        return []
    try:
        loaded = json.loads(stripped)
    except ValueError:
        loaded = None
    candidates = loaded if isinstance(loaded, list) else [loaded] if isinstance(loaded, dict) else []
    if not candidates:
        for line in stripped.splitlines():
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if isinstance(item, dict):
                candidates.append(item)
    return [item for item in candidates if isinstance(item, dict)]


def tag_values(event: dict[str, object], name: str) -> set[str]:
    tags = event.get("tags")
    if not isinstance(tags, list):
        return set()
    return {
        str(tag[1])
        for tag in tags
        if isinstance(tag, list) and len(tag) >= 2 and tag[0] == name
    }


def role_tag_values(event: dict[str, object], name: str, role: str) -> set[str]:
    tags = event.get("tags")
    if not isinstance(tags, list):
        return set()
    return {
        str(tag[1])
        for tag in tags
        if isinstance(tag, list) and len(tag) >= 3 and tag[0] == name and tag[2] == role
    }


def matches(
    event: dict[str, object],
    target_pubkey: str | None,
    author_pubkeys: list[str] | None,
    group_ids: list[str] | None,
    since: int | None,
    kinds: list[int] | None,
) -> bool:
    if kinds:
        try:
            if int(event.get("kind")) not in kinds:
                return False
        except (TypeError, ValueError):
            return False
    if target_pubkey and target_pubkey not in tag_values(event, "p"):
        return False
    if author_pubkeys and event.get("pubkey") not in author_pubkeys:
        return False
    if group_ids and not tag_values(event, "h").intersection(group_ids):
        return False
    if since is None:
        return True
    try:
        return int(event.get("created_at")) >= since
    except (TypeError, ValueError):
        return False


def with_source_relay(events: list[dict[str, object]], relay: str) -> list[dict[str, object]]:
    for event in events:
        event["relay"] = relay
    return events

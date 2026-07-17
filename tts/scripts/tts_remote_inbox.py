#!/usr/bin/env python3
"""Durable inbox for fetched remote TTS events."""

from __future__ import annotations

import hashlib
from pathlib import Path

from tts_remote_state import read_json, remote_dir, write_json


def stage_events(events: list[dict[str, object]]) -> None:
    for event in events:
        event_id = str(event.get("id") or "")
        if not event_id:
            continue
        destination = event_path(event_id)
        if not destination.exists():
            write_json(destination, event)


def pending_events() -> list[dict[str, object]]:
    events = []
    for path in inbox_directory().glob("*.json"):
        event = read_json(path, {})
        if isinstance(event, dict) and event.get("id"):
            events.append(event)
    return events


def acknowledge_event(event_id: str) -> None:
    event_path(event_id).unlink(missing_ok=True)


def event_path(event_id: str) -> Path:
    filename = hashlib.sha256(event_id.encode("utf-8")).hexdigest()
    return inbox_directory() / f"{filename}.json"


def inbox_directory() -> Path:
    path = remote_dir() / "pending-events"
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    return path

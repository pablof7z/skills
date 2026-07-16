#!/usr/bin/env python3
"""Long-running lifecycle for the paired-laptop TTS listener."""

from __future__ import annotations

import json
import os
import sys
import time

from tts_remote_config import remote_config
from tts_remote_daemon import process_events
from tts_remote_groups import reconcile_paired_channels
from tts_remote_profile import (
    profile_refresh_interval,
    publish_endpoint_profile,
    refresh_peer_profiles,
)
from tts_remote_state import ensure_laptop_identity, peers, remote_dir, write_json


def daemon_run(args) -> int:
    laptop = ensure_laptop_identity()
    write_json(
        remote_dir() / "daemon.json",
        {"running": True, "pid": os.getpid(), "started_at": int(time.time())},
    )
    processed = 0
    deadline = time.monotonic() + args.wait_seconds if args.wait_seconds is not None else None
    next_profile_refresh = 0.0
    next_channel_reconcile = 0.0
    next_event_poll = 0.0
    force_profile_refresh = True
    try:
        while True:
            now = time.monotonic()
            if now >= next_profile_refresh:
                try:
                    publish_laptop_profiles(laptop, force=force_profile_refresh)
                    refresh_peer_profiles()
                except RuntimeError as error:
                    retrying("profile refresh", error, args.once)
                    next_profile_refresh = time.monotonic() + listener_retry_interval()
                else:
                    force_profile_refresh = False
                    next_profile_refresh = time.monotonic() + profile_refresh_interval()
            if now >= next_channel_reconcile:
                try:
                    reconcile_paired_channels(laptop, peers())
                except RuntimeError as error:
                    retrying("channel reconciliation", error, False)
                    next_channel_reconcile = time.monotonic() + listener_retry_interval()
                else:
                    next_channel_reconcile = time.monotonic() + channel_reconcile_interval()
            if now >= next_event_poll:
                try:
                    processed += process_events(args, laptop)
                except RuntimeError as error:
                    retrying("event polling", error, args.once)
                    next_event_poll = time.monotonic() + listener_retry_interval()
                else:
                    next_event_poll = 0.0
            if args.once or (deadline is not None and time.monotonic() >= deadline):
                break
            time.sleep(0.25)
        print(json.dumps({"status": "idle", "processed": min(processed, args.max_events)}, indent=2))
        return 0
    finally:
        write_json(
            remote_dir() / "daemon.json",
            {"running": False, "pid": os.getpid(), "stopped_at": int(time.time())},
        )


def retrying(operation: str, error: RuntimeError, fail_fast: bool) -> None:
    if fail_fast:
        raise error
    print(f"TTS listener will retry {operation}: {error}", file=sys.stderr, flush=True)


def publish_laptop_profiles(laptop: dict[str, object], *, force: bool = False) -> None:
    relays = {str(remote_config()["relay"])}
    relays.update(
        str(peer.get("relay") or "")
        for peer in peers()
        if peer.get("approved") and not peer.get("revoked_at")
    )
    for relay in relays:
        publish_endpoint_profile(laptop, relay, force=force)


def channel_reconcile_interval() -> float:
    return environment_interval("TTS_CHANNEL_RECONCILE_SECONDS", 60.0)


def listener_retry_interval() -> float:
    return environment_interval("TTS_LISTENER_RETRY_SECONDS", 5.0)


def environment_interval(name: str, default: float) -> float:
    try:
        return max(0.01, float(os.environ.get(name, str(default))))
    except ValueError:
        return default

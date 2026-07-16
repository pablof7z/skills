#!/usr/bin/env python3
"""Nostr signing helpers for remote TTS."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import time

from tts_remote_state import fake_nostr_enabled, pubkey_for_nsec, public_key_for_secret


def canonical(event: dict[str, object]) -> str:
    unsigned = {key: value for key, value in event.items() if key not in {"id", "sig", "relay"}}
    return json.dumps(unsigned, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def fake_signed_event(*, kind: int, content: str, tags: list[list[str]], nsec: str, relay: str | None = None) -> dict[str, object]:
    event: dict[str, object] = {
        "kind": kind,
        "pubkey": pubkey_for_nsec(nsec),
        "created_at": int(time.time()),
        "tags": tags,
        "content": content,
    }
    event["id"] = hashlib.sha256(canonical(event).encode("utf-8")).hexdigest()
    event["sig"] = hashlib.sha256((str(event["id"]) + str(event["pubkey"])).encode("utf-8")).hexdigest()
    if relay:
        event["relay"] = relay
    return event


def signed_event(*, kind: int, content: str, tags: list[list[str]], nsec: str, relay: str | None = None) -> dict[str, object]:
    if fake_nostr_enabled():
        return fake_signed_event(kind=kind, content=content, tags=tags, nsec=nsec, relay=relay)
    return nak_signed_event(kind=kind, content=content, tags=tags, nsec=nsec, relay=relay)


def nak_signed_event(*, kind: int, content: str, tags: list[list[str]], nsec: str, relay: str | None = None) -> dict[str, object]:
    command = [nak_bin(), "event", "--kind", str(kind), "--content", content]
    for tag in tags:
        command.extend(["--tag", "=".join(tag)])
    process = subprocess.run(
        command,
        env={**os.environ, "NOSTR_SECRET_KEY": nsec},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise RuntimeError(process.stderr.strip() or "nak signing failed")
    lines = process.stdout.splitlines()
    if not lines:
        raise RuntimeError("nak signing produced no event")
    event = json.loads(lines[-1])
    if relay:
        event["relay"] = relay
    return event


def verify_event(event: dict[str, object]) -> bool:
    event_id = hashlib.sha256(canonical(event).encode("utf-8")).hexdigest()
    fake_sig = hashlib.sha256((event_id + str(event.get("pubkey"))).encode("utf-8")).hexdigest()
    if fake_nostr_enabled() and event.get("id") == event_id and event.get("sig") == fake_sig:
        return True
    process = subprocess.run(
        [nak_bin(), "verify"],
        input=json.dumps(event),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return process.returncode == 0


def public_key(nsec: str) -> str:
    return public_key_for_secret(nsec)


def nak_bin() -> str:
    return os.environ.get("TTS_NAK_BIN", "nak")

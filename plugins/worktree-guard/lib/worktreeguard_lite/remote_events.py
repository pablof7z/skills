"""Small signed-event helpers for WorktreeGuard remote approval."""

from __future__ import annotations

import hashlib
import json
import secrets
import time
from typing import Any


PRODUCT = "worktree-guard"
PAIR_CODE_VERSION = 1
PAIRING_KIND = 9001
APPROVAL_KIND = 9


def new_secret(prefix: str) -> str:
    return f"{prefix}_{secrets.token_urlsafe(32)}"


def new_key_secret() -> str:
    return secrets.token_hex(32)


def pubkey_for_secret(secret: str) -> str:
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def signed_event(
    *,
    kind: int,
    secret: str,
    content: dict[str, Any],
    tags: list[list[str]] | None = None,
    created_at: int | None = None,
) -> dict[str, Any]:
    event = {
        "pubkey": pubkey_for_secret(secret),
        "created_at": created_at or int(time.time()),
        "kind": kind,
        "tags": tags or [],
        "content": json.dumps(content, sort_keys=True, separators=(",", ":")),
    }
    event["id"] = event_id(event)
    event["sig"] = hashlib.sha256((event["id"] + secret).encode("utf-8")).hexdigest()
    event["_secret"] = secret
    return event


def event_id(event: dict[str, Any]) -> str:
    payload = [
        0,
        event["pubkey"],
        event["created_at"],
        event["kind"],
        event.get("tags", []),
        event.get("content", ""),
    ]
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def event_content(event: dict[str, Any]) -> dict[str, Any]:
    try:
        payload = json.loads(str(event.get("content") or "{}"))
    except json.JSONDecodeError:
        return {}
    return payload if isinstance(payload, dict) else {}


def has_tag(event: dict[str, Any], name: str, value: str) -> bool:
    for tag in event.get("tags", []):
        if isinstance(tag, list) and len(tag) >= 2 and tag[0] == name and tag[1] == value:
            return True
    return False

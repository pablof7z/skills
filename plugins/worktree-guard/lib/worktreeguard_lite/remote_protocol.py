"""Protocol validation helpers for WorktreeGuard remote approval."""

from __future__ import annotations

import time
from typing import Any

from .remote_events import APPROVAL_KIND, PRODUCT, event_content, has_tag, structurally_valid_event
from .remote_transport import poll_events


def valid_decision(
    event: dict[str, Any],
    request_id: str,
    record: dict[str, Any],
    remote: dict[str, Any],
) -> str | None:
    if not has_tag(event, "e", request_id) or not structurally_valid_event(event):
        return None
    if record.get("used_at") is not None or event.get("pubkey") != record.get("laptop_pubkey"):
        return None
    if not has_tag(event, "p", str(record.get("backend_pubkey") or "")):
        return None
    if not has_tag(event, "h", PRODUCT) or not has_tag(event, "product", PRODUCT):
        return None
    if int(event.get("created_at", 0)) < int(record.get("created_at", 0)):
        return None
    if int(event.get("created_at", 0)) > int(record.get("expires_at", 0)):
        return None
    if int(time.time()) > int(record.get("expires_at", 0)):
        return None
    approved = remote.get("approved_peers", {})
    if not isinstance(approved, dict) or event.get("pubkey") not in approved:
        return None
    payload = event_content(event)
    if payload.get("request_id") != request_id or payload.get("product") != PRODUCT:
        return None
    raw = str(payload.get("decision") or "").lower()
    if raw in {"allow-session", "session", "allow"}:
        return "session"
    if raw in {"allow-once", "once", "operation"}:
        return "once"
    if raw == "deny":
        return "deny"
    return None


def pending_record(
    request: Any,
    relay: str,
    laptop_pubkey: str,
    backend_pubkey: str,
) -> dict[str, Any]:
    now = int(time.time())
    return {
        "relay": relay,
        "laptop_pubkey": laptop_pubkey,
        "backend_pubkey": backend_pubkey,
        "operation": request.operation,
        "worktree": request.worktree,
        "repository": request.repository,
        "reason": request.reason,
        "session": request.session,
        "ttl_seconds": request.ttl_seconds,
        "requested_scope": request.requested_scope,
        "created_at": now,
        "expires_at": now + max(1, request.ttl_seconds),
    }


def request_author(relay: str, request_id: str) -> str:
    if not relay:
        return ""
    for event in poll_events(relay, {APPROVAL_KIND}, time.monotonic()):
        if event.get("id") == request_id and has_tag(event, "h", PRODUCT):
            return str(event.get("pubkey") or "")
    return ""


def default_relay(remote: dict[str, Any]) -> str:
    for collection in ("pair_offers", "approved_peers"):
        values = remote.get(collection, {})
        if isinstance(values, dict):
            for item in values.values():
                if isinstance(item, dict) and item.get("relay"):
                    return str(item["relay"])
    return ""

"""Remote approval request and decision handling."""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .remote_events import (
    APPROVAL_KIND,
    PAIRING_KIND,
    PRODUCT,
    event_content,
    has_tag,
    signed_event,
)
from .remote_pairing import identity, valid_pairing_event
from .remote_protocol import default_relay, pending_record, request_author, valid_decision
from .remote_transport import poll_events, transport
from .storage import create_grant, load_state, save_state


@dataclass(frozen=True)
class RemoteApprovalRequest:
    operation: str
    worktree: str
    repository: str
    reason: str
    session: str
    ttl_seconds: int
    requested_scope: str = "session"


def request_remote_approval(
    request: RemoteApprovalRequest,
    *,
    wait_seconds: int,
    request_id: str | None = None,
    create_grant_on_allow: bool = True,
) -> str | None:
    state = load_state()
    remote = state.get("remote", {})
    approved = remote.get("approved_peers", {})
    if not isinstance(approved, dict) or not approved:
        return None
    laptop_pubkey, peer = next(iter(approved.items()))
    relay = str(peer.get("relay") or "")
    if not relay:
        return None

    backend = identity(state, "backend")
    active_id = request_id or publish_request(backend, relay, laptop_pubkey, request)
    pending = state.setdefault("remote", {}).setdefault("pending_requests", {})
    pending.setdefault(active_id, pending_record(request, relay, laptop_pubkey, backend["pubkey"]))
    save_state(state)
    deadline = time.monotonic() + max(0, wait_seconds)
    return consume_decision(active_id, deadline, create_grant_on_allow=create_grant_on_allow)


def publish_request(
    backend: dict[str, str],
    relay: str,
    laptop_pubkey: str,
    request: RemoteApprovalRequest,
) -> str:
    content = {
        "operation": request.operation,
        "worktree": request.worktree,
        "repository": request.repository,
        "reason": request.reason,
        "session": request.session,
        "ttl_seconds": request.ttl_seconds,
        "requested_scope": request.requested_scope,
        "product": PRODUCT,
    }
    event = signed_event(
        kind=APPROVAL_KIND,
        secret=backend["secret"],
        tags=[
            ["p", laptop_pubkey],
            ["h", PRODUCT],
            ["product", PRODUCT],
            ["wtg", "approval-request"],
        ],
        content=content,
    )
    transport().publish(relay, event)
    return str(event["id"])


def publish_decision(request_id: str, decision: str) -> str:
    state = load_state()
    remote = state.setdefault("remote", {})
    laptop = identity(state, "laptop")
    pending = remote.get("pending_requests", {}).get(request_id, {})
    relay = str(pending.get("relay") or default_relay(remote))
    backend_pubkey = str(pending.get("backend_pubkey") or request_author(relay, request_id) or "")
    event = signed_event(
        kind=APPROVAL_KIND,
        secret=laptop["secret"],
        tags=[
            ["e", request_id],
            ["p", backend_pubkey],
            ["h", PRODUCT],
            ["product", PRODUCT],
            ["wtg", "approval-decision"],
        ],
        content={"decision": decision, "request_id": request_id, "product": PRODUCT},
    )
    transport().publish(relay, event)
    return str(event["id"])


def laptop_requests(deadline: float) -> list[dict[str, Any]]:
    state = load_state()
    laptop = identity(state, "laptop")
    accept_pairing_events(state, laptop, deadline)
    state = load_state()
    approved = state.get("remote", {}).get("approved_peers", {})
    relays = laptop_relays(state)
    requests: list[dict[str, Any]] = []
    for relay in relays:
        for event in poll_events(relay, {APPROVAL_KIND}, deadline):
            if not has_tag(event, "p", laptop["pubkey"]):
                continue
            if not has_tag(event, "h", PRODUCT) or not has_tag(event, "product", PRODUCT):
                continue
            if not isinstance(approved, dict) or event.get("pubkey") not in approved:
                continue
            payload = event_content(event)
            if payload.get("product") != PRODUCT:
                continue
            if not payload.get("operation") or not payload.get("repository"):
                continue
            item = dict(payload)
            item["id"] = event["id"]
            item["relay"] = relay
            item["pubkey"] = event.get("pubkey", "")
            requests.append(item)
    return requests


def accept_pairing_events(
    state: dict[str, Any],
    laptop: dict[str, str],
    deadline: float,
) -> None:
    remote = state.setdefault("remote", {})
    offers = remote.setdefault("pair_offers", {})
    approved = remote.setdefault("approved_peers", {})
    changed = False
    for relay in laptop_relays(state):
        for event in poll_events(relay, {PAIRING_KIND}, deadline):
            payload = event_content(event)
            pairing_id = str(payload.get("pairing_id") or "")
            offer = offers.get(pairing_id)
            if not isinstance(offer, dict):
                continue
            now = int(time.time())
            if not valid_pairing_event(event, laptop_pubkey=laptop["pubkey"], offer=offer, now=now):
                continue
            offer["used_at"] = now
            save_state(state)
            approved[str(event.get("pubkey") or "")] = {
                "role": "backend",
                "relay": relay,
                "pairing_id": pairing_id,
                "product": PRODUCT,
                "approved_at": now,
            }
            changed = True
            break
    if changed:
        save_state(state)


def laptop_relays(state: dict[str, Any]) -> list[str]:
    remote = state.get("remote", {})
    relays: list[str] = []
    offers = remote.get("pair_offers", {})
    if isinstance(offers, dict):
        for offer in offers.values():
            if isinstance(offer, dict) and offer.get("relay"):
                relays.append(str(offer["relay"]))
    approved = remote.get("approved_peers", {})
    if isinstance(approved, dict):
        for peer in approved.values():
            if isinstance(peer, dict) and peer.get("relay"):
                relays.append(str(peer["relay"]))
    return sorted(set(relays))


def consume_decision(
    request_id: str,
    deadline: float,
    *,
    create_grant_on_allow: bool = True,
) -> str | None:
    state = load_state()
    remote = state.setdefault("remote", {})
    pending = remote.setdefault("pending_requests", {})
    record = pending.get(request_id)
    if not isinstance(record, dict) or record.get("used_at") is not None:
        return None
    relay = str(record.get("relay") or "")
    events = poll_events(relay, {APPROVAL_KIND}, deadline)
    for event in events:
        decision = valid_decision(event, request_id, record, remote)
        if decision is None:
            continue
        record["used_at"] = int(time.time())
        record["decision"] = decision
        save_state(state)
        if decision in {"once", "session"} and create_grant_on_allow:
            create_grant(
                base_path=Path(str(record["repository"])),
                scope=decision,
                reason=str(record["reason"]),
                ttl_seconds=int(record["ttl_seconds"]),
                session_id=str(record.get("session") or ""),
            )
        return decision if decision in {"once", "session"} else None
    return None

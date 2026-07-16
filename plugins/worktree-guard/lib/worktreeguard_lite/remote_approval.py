"""Remote approval request and decision handling."""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .remote_events import (
    APPROVAL_KIND,
    PAIRING_KIND,
    event_content,
    has_tag,
    new_secret,
    signed_event,
)
from .remote_pairing import identity
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
    pending.setdefault(active_id, pending_record(request, relay, laptop_pubkey))
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
    }
    event = signed_event(
        kind=APPROVAL_KIND,
        secret=backend["secret"],
        tags=[["p", laptop_pubkey], ["wtg", "approval-request"]],
        content=content,
    )
    transport().publish(relay, event)
    return str(event["id"])


def publish_decision(request_id: str, decision: str, *, peer_pubkey: str | None = None) -> str:
    state = load_state()
    remote = state.setdefault("remote", {})
    laptop = identity(state, "laptop")
    if peer_pubkey and peer_pubkey != laptop["pubkey"]:
        laptop = {"secret": new_secret("external"), "pubkey": peer_pubkey}
    pending = remote.get("pending_requests", {}).get(request_id, {})
    relay = str(pending.get("relay") or default_relay(remote))
    event = signed_event(
        kind=APPROVAL_KIND,
        secret=laptop["secret"],
        tags=[["e", request_id], ["wtg", "approval-decision"]],
        content={"decision": decision, "request_id": request_id},
    )
    event["pubkey"] = laptop["pubkey"]
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
            if not isinstance(approved, dict) or event.get("pubkey") not in approved:
                continue
            payload = event_content(event)
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
            if not has_tag(event, "p", laptop["pubkey"]):
                continue
            payload = event_content(event)
            pairing_id = str(payload.get("pairing_id") or "")
            offer = offers.get(pairing_id)
            if not isinstance(offer, dict):
                continue
            if payload.get("secret") != offer.get("secret"):
                continue
            approved[str(event.get("pubkey") or "")] = {
                "role": "backend",
                "relay": relay,
                "pairing_id": pairing_id,
                "approved_at": int(time.time()),
            }
            offer["used_at"] = int(time.time())
            changed = True
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
            )
        return decision if decision in {"once", "session"} else None
    return None


def valid_decision(
    event: dict[str, Any],
    request_id: str,
    record: dict[str, Any],
    remote: dict[str, Any],
) -> str | None:
    if not has_tag(event, "e", request_id):
        return None
    if int(event.get("created_at", 0)) < int(record.get("created_at", 0)):
        return None
    if int(time.time()) > int(record.get("expires_at", 0)):
        return None
    approved = remote.get("approved_peers", {})
    if not isinstance(approved, dict) or event.get("pubkey") not in approved:
        return None
    payload = event_content(event)
    raw = str(payload.get("decision") or "").lower()
    if raw in {"allow-session", "session", "allow"}:
        return "session"
    if raw in {"allow-once", "once", "operation"}:
        return "once"
    if raw == "deny":
        return "deny"
    return None


def pending_record(
    request: RemoteApprovalRequest,
    relay: str,
    laptop_pubkey: str,
) -> dict[str, Any]:
    now = int(time.time())
    return {
        "relay": relay,
        "laptop_pubkey": laptop_pubkey,
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


def default_relay(remote: dict[str, Any]) -> str:
    offers = remote.get("pair_offers", {})
    if isinstance(offers, dict):
        for offer in offers.values():
            if isinstance(offer, dict) and offer.get("relay"):
                return str(offer["relay"])
    approved = remote.get("approved_peers", {})
    if isinstance(approved, dict):
        for peer in approved.values():
            if isinstance(peer, dict) and peer.get("relay"):
                return str(peer["relay"])
    return ""

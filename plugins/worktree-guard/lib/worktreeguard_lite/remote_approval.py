"""Remote approval request and decision handling."""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .core import WorktreeGuardError
from .remote_events import (
    APPROVAL_KIND,
    GROUP_EDIT_METADATA_KIND,
    GROUP_PUT_USER_KIND,
    PAIRING_KIND,
    PRODUCT,
    event_content,
    has_tag,
    signed_event,
)
from .remote_pairing import identity, publish_group_event, valid_pairing_event
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
    group_id = str(peer.get("group_id") or "")
    if not relay or not group_id:
        return None

    backend = identity(state, "backend")
    active_id = request_id or publish_request(backend, relay, laptop_pubkey, group_id, request)
    pending = state.setdefault("remote", {}).setdefault("pending_requests", {})
    pending.setdefault(
        active_id,
        pending_record(request, relay, laptop_pubkey, backend["pubkey"], group_id),
    )
    save_state(state)
    deadline = time.monotonic() + max(0, wait_seconds)
    return consume_decision(active_id, deadline, create_grant_on_allow=create_grant_on_allow)


def publish_request(
    backend: dict[str, str],
    relay: str,
    laptop_pubkey: str,
    group_id: str,
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
            ["h", group_id],
            ["product", PRODUCT],
            ["wtg", "approval-request"],
        ],
        content=content,
    )
    published = transport().publish(relay, event)
    return str(published["id"])


def publish_decision(request_id: str, decision: str) -> str:
    state = load_state()
    remote = state.setdefault("remote", {})
    laptop = identity(state, "laptop")
    pending = remote.get("pending_requests", {}).get(request_id, {})
    if not isinstance(pending, dict) or not pending:
        raise WorktreeGuardError("Approval request is not retained on this laptop.")
    if int(pending.get("expires_at", 0)) <= int(time.time()):
        raise WorktreeGuardError("Approval request expired.")
    relay = str(pending.get("relay") or default_relay(remote))
    group_id = str(pending.get("group_id") or "")
    backend_pubkey = str(
        pending.get("backend_pubkey")
        or request_author(relay, request_id, group_id=group_id, p_tag=laptop["pubkey"])
        or ""
    )
    event = signed_event(
        kind=APPROVAL_KIND,
        secret=laptop["secret"],
        tags=[
            ["e", request_id],
            ["p", backend_pubkey],
            ["h", group_id],
            ["product", PRODUCT],
            ["wtg", "approval-decision"],
        ],
        content={
            "decision": decision,
            "request_id": request_id,
            "session": str(pending.get("session") or ""),
            "product": PRODUCT,
        },
    )
    published = transport().publish(relay, event)
    now = int(time.time())
    pending["handled_at"] = now
    pending["decision_event_id"] = str(published["id"])
    remote.setdefault("consumed_request_ids", {})[request_id] = now
    save_state(state)
    return str(published["id"])


def laptop_requests(deadline: float) -> list[dict[str, Any]]:
    state = load_state()
    laptop = identity(state, "laptop")
    accept_pairing_events(state, laptop, deadline)
    state = load_state()
    remote = state.setdefault("remote", {})
    approved = remote.get("approved_peers", {})
    consumed = remote.setdefault("consumed_request_ids", {})
    retained = remote.setdefault("pending_requests", {})
    requests: list[dict[str, Any]] = []
    now = int(time.time())
    for backend_pubkey, peer in approved.items() if isinstance(approved, dict) else []:
        if not isinstance(peer, dict):
            continue
        relay = str(peer.get("relay") or "")
        group_id = str(peer.get("group_id") or "")
        if not relay or not group_id:
            continue
        events = poll_events(
            relay,
            {APPROVAL_KIND},
            deadline,
            p_tag=laptop["pubkey"],
            h_tag=group_id,
        )
        for event in events:
            event_id = str(event.get("id") or "")
            if event_id in consumed or event.get("pubkey") != backend_pubkey:
                continue
            if not has_tag(event, "product", PRODUCT):
                continue
            payload = event_content(event)
            if payload.get("product") != PRODUCT:
                continue
            if not payload.get("operation") or not payload.get("repository"):
                continue
            expires_at = int(event.get("created_at", 0)) + max(1, int(payload.get("ttl_seconds", 0)))
            if expires_at <= now:
                consumed[event_id] = now
                continue
            item = dict(payload)
            item["id"] = event_id
            item["relay"] = relay
            item["pubkey"] = backend_pubkey
            item["group_id"] = group_id
            item["created_at"] = int(event.get("created_at", 0))
            item["expires_at"] = expires_at
            retained.setdefault(event_id, item)
            requests.append(item)
    save_state(state)
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
    for pairing_id, offer in list(offers.items()):
        if not isinstance(offer, dict) or offer.get("used_at") is not None:
            continue
        relay = str(offer.get("relay") or "")
        group_id = str(offer.get("group_id") or "")
        for event in poll_events(
            relay,
            {PAIRING_KIND},
            deadline,
            p_tag=laptop["pubkey"],
            h_tag=group_id,
        ):
            payload = event_content(event)
            if str(payload.get("pairing_id") or "") != pairing_id:
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
                "group_id": group_id,
                "approved_at": now,
            }
            added = publish_group_event(
                laptop["secret"],
                relay,
                GROUP_PUT_USER_KIND,
                [["h", group_id], ["p", str(event.get("pubkey") or "")]],
            )
            if added:
                publish_group_event(
                    laptop["secret"],
                    relay,
                    GROUP_EDIT_METADATA_KIND,
                    [
                        ["h", group_id],
                        ["name", "WorktreeGuard approvals"],
                        ["closed"],
                        ["public"],
                    ],
                )
            changed = True
            break
    if changed:
        save_state(state)


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
    if int(record.get("expires_at", 0)) <= int(time.time()):
        record["used_at"] = int(time.time())
        record["decision"] = "expired"
        save_state(state)
        return None
    relay = str(record.get("relay") or "")
    events = poll_events(
        relay,
        {APPROVAL_KIND},
        deadline,
        p_tag=str(record.get("backend_pubkey") or ""),
        h_tag=str(record.get("group_id") or ""),
    )
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

"""Endpoint orchestration for remote human pairing and NIP-29 messages."""

from __future__ import annotations

import json
import socket
import time
from pathlib import Path
from typing import Any, Callable, Union

from .errors import RemoteHumanError
from .models import GROUP_MESSAGE_KIND, PAIRING_REQUEST_KIND, PAIRING_VERSION, PairingCode, group_for
from .state import JsonState


Clock = Callable[[], Union[int, float]]


class LaptopEndpoint:
    def __init__(self, *, product: str, relay_url: str, pubkey: str, state_path: Path, now: Clock = time.time):
        self.product = product
        self.relay_url = relay_url
        self.pubkey = pubkey
        self.state = JsonState(state_path)
        self.now = now

    def create_pairing_code(self, pairing_id: str, secret: str, expires_in: int) -> PairingCode:
        return PairingCode(
            version=PAIRING_VERSION,
            product=self.product,
            relay_url=self.relay_url,
            laptop_pubkey=self.pubkey,
            pairing_id=pairing_id,
            expires_at=int(self.now()) + expires_in,
            secret=secret,
        )

    def consume_pairing_request(self, event: dict[str, Any]) -> dict[str, Any]:
        content = _json_content(event)
        code = PairingCode.from_json(json.dumps(content["pairing"], sort_keys=True))
        _validate_pairing(code, product=self.product, now=int(self.now()))
        if content.get("secret") != code.secret:
            raise RemoteHumanError("secret_mismatch", "Pairing request secret does not match the code.")
        state = self.state.load()
        if code.pairing_id in state["consumed_pairings"]:
            raise RemoteHumanError("pairing_replayed", "Pairing code has already been consumed.")
        backend_pubkey = str(event["pubkey"])
        state["consumed_pairings"].append(code.pairing_id)
        state["approved_backends"][backend_pubkey] = {
            "product": code.product,
            "relay_url": code.relay_url,
            "approved_at": int(self.now()),
            "pairing_id": code.pairing_id,
            "group": group_for(code.product, code.pairing_id),
        }
        self.state.save(state)
        return state["approved_backends"][backend_pubkey]

    def receive_request(self, event: dict[str, Any]) -> dict[str, Any]:
        state = self.state.load()
        backend = state["approved_backends"].get(event.get("pubkey"))
        if backend is None:
            raise RemoteHumanError("backend_not_approved", "Request came from an unapproved backend.")
        if backend.get("revoked_at") is not None:
            raise RemoteHumanError("backend_revoked", "Request came from a revoked backend.")
        if event["id"] not in state["seen_events"]:
            state["seen_events"].append(event["id"])
            self.state.save(state)
        return event

    def reply(self, request: dict[str, Any], content: str) -> dict[str, Any]:
        state = self.state.load()
        request_id = request["id"]
        if request_id in state["replied_requests"]:
            return state["replied_requests"][request_id]
        event = {
            "kind": GROUP_MESSAGE_KIND,
            "pubkey": self.pubkey,
            "content": content,
            "tags": [["e", request_id], ["p", request["pubkey"]]],
            "created_at": int(self.now()),
        }
        event["id"] = _stable_event_id(event)
        state["replied_requests"][request_id] = event
        self.state.save(state)
        transport = request.get("_transport")
        return transport.publish(event) if transport is not None else event

    def revoke_backend(self, backend_pubkey: str) -> None:
        state = self.state.load()
        backend = state["approved_backends"].get(backend_pubkey)
        if backend is not None:
            backend["revoked_at"] = int(self.now())
            self.state.save(state)


class BackendEndpoint:
    def __init__(self, *, product: str, hostname: str | None, state_path: Path, transport: Any, now: Clock = time.time):
        self.product = product
        self.hostname = hostname or socket.gethostname()
        self.state = JsonState(state_path)
        self.transport = transport
        self.now = now
        identity = self._load_or_create_identity()
        self.nsec = identity["nsec"]
        self.pubkey = identity["pubkey"]
        if hasattr(self.transport, "nsec") and not getattr(self.transport, "nsec"):
            self.transport.nsec = self.nsec

    def publish_pairing_request(self, code: PairingCode) -> dict[str, Any]:
        _validate_pairing(code, product=self.product, now=int(self.now()))
        self.transport.publish({
            "kind": 0,
            "pubkey": self.pubkey,
            "content": json.dumps({"name": f"{self.hostname} {self.product} daemon"}, sort_keys=True),
            "tags": [],
            "created_at": int(self.now()),
        })
        content = {"pairing": json.loads(code.to_json()), "secret": code.secret}
        return self.transport.publish({
            "kind": PAIRING_REQUEST_KIND,
            "pubkey": self.pubkey,
            "content": json.dumps(content, sort_keys=True),
            "tags": [["p", code.laptop_pubkey], ["d", code.pairing_id]],
            "created_at": int(self.now()),
        })

    def send_request(self, content: str, request_id: str) -> dict[str, Any]:
        event = {
            "kind": GROUP_MESSAGE_KIND,
            "pubkey": self.pubkey,
            "content": content,
            "tags": [["d", request_id]],
            "created_at": int(self.now()),
        }
        event["id"] = _stable_event_id(event)
        published = self.transport.publish(event)
        published["_transport"] = self.transport
        return published

    def collect_replies(self, request_id: str, timeout_seconds: float) -> list[dict[str, Any]]:
        deadline = time.monotonic() + max(0.0, timeout_seconds)
        seen: set[str] = set()
        while True:
            target_ids = self._request_event_ids(request_id)
            replies = []
            for event in self.transport.query({"kind": GROUP_MESSAGE_KIND}):
                if not any(["e", target_id] in event.get("tags", []) for target_id in target_ids):
                    continue
                if event["id"] in seen:
                    continue
                seen.add(event["id"])
                replies.append(event)
            if replies:
                return replies
            if time.monotonic() >= deadline:
                raise RemoteHumanError("timeout", "Timed out waiting for a remote human reply.", {"request_id": request_id})
            time.sleep(min(0.01, deadline - time.monotonic()))

    def _request_event_ids(self, request_id: str) -> list[str]:
        ids = [
            event["id"]
            for event in self.transport.query({"kind": GROUP_MESSAGE_KIND, "authors": [self.pubkey]})
            if ["d", request_id] in event.get("tags", [])
        ]
        return ids or [request_id]

    def _load_or_create_identity(self) -> dict[str, str]:
        state = self.state.load()
        state.setdefault("backend", {})
        identity = state["backend"].setdefault("products", {}).setdefault(self.product, {})
        if not identity.get("nsec"):
            identity["nsec"] = self.transport.generate_secret_key()
        if not identity.get("pubkey"):
            identity["pubkey"] = self.transport.public_key_for_secret(identity["nsec"])
            self.state.save(state)
        return {"nsec": str(identity["nsec"]), "pubkey": str(identity["pubkey"])}


def _validate_pairing(code: PairingCode, *, product: str, now: int) -> None:
    if code.version != PAIRING_VERSION:
        raise RemoteHumanError("version_mismatch", "Unsupported pairing code version.")
    if code.product != product:
        raise RemoteHumanError("product_mismatch", "Pairing code is for a different product.")
    if code.expires_at <= now:
        raise RemoteHumanError("pairing_expired", "Pairing code has expired.")


def _json_content(event: dict[str, Any]) -> dict[str, Any]:
    try:
        payload = json.loads(str(event.get("content", "")))
    except json.JSONDecodeError as error:
        raise RemoteHumanError("invalid_event", "Event content is not valid JSON.") from error
    if not isinstance(payload, dict):
        raise RemoteHumanError("invalid_event", "Event content must be a JSON object.")
    return payload


def _stable_event_id(event: dict[str, Any]) -> str:
    from .transport import event_id

    return event_id(event)

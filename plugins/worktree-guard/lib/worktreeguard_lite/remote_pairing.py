"""Pairing state and commands for attended-laptop approval."""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import time
from dataclasses import dataclass
from typing import Any

from .core import WorktreeGuardError
from .remote_events import (
    PAIR_CODE_VERSION,
    PAIRING_KIND,
    PRODUCT,
    GROUP_CREATE_KIND,
    has_tag,
    new_key_secret,
    new_secret,
    pubkey_for_secret,
    signed_event,
    structurally_valid_event,
)
from .remote_transport import transport
from .storage import load_state, save_state


@dataclass(frozen=True)
class PairOffer:
    pair_code: str
    relay: str
    laptop_pubkey: str
    pairing_id: str
    secret: str
    expires_at: int


def create_pair_offer(*, relay: str, ttl_seconds: int = 600) -> PairOffer:
    state = load_state()
    laptop = identity(state, "laptop")
    now = int(time.time())
    secret = new_secret("pair")
    payload = {
        "version": PAIR_CODE_VERSION,
        "product": PRODUCT,
        "relay": relay,
        "laptop_pubkey": laptop["pubkey"],
        "pairing_id": new_secret("pid"),
        "created_at": now,
        "expires_at": now + max(30, ttl_seconds),
        "secret": secret,
    }
    payload["group_id"] = "wtg-" + payload["pairing_id"].removeprefix("pid_")
    state.setdefault("remote", {}).setdefault("pair_offers", {})[payload["pairing_id"]] = payload
    save_state(state)
    publish_group_event(
        laptop["secret"], relay, GROUP_CREATE_KIND, [["h", payload["group_id"]]]
    )
    return PairOffer(
        pair_code=json.dumps(payload, sort_keys=True, separators=(",", ":")),
        relay=relay,
        laptop_pubkey=laptop["pubkey"],
        pairing_id=payload["pairing_id"],
        secret=secret,
        expires_at=payload["expires_at"],
    )


def connect_pair_code(pair_code: str) -> dict[str, Any]:
    payload = decode_pair_code(pair_code)
    state = load_state()
    backend = identity(state, "backend")
    connected = state.setdefault("remote", {}).setdefault("connected_pairings", {})
    approved = state.setdefault("remote", {}).setdefault("approved_peers", {})
    approved[payload["laptop_pubkey"]] = {
        "role": "laptop",
        "relay": payload["relay"],
        "pairing_id": payload["pairing_id"],
        "product": PRODUCT,
        "group_id": payload["group_id"],
        "approved_at": int(time.time()),
    }
    save_state(state)
    if payload["pairing_id"] not in connected:
        publish_backend_metadata(backend["secret"], payload["relay"])
        publish_pairing_event(backend["secret"], payload)
        connected[payload["pairing_id"]] = int(time.time())
        save_state(state)
    return {
        "status": "paired",
        "relay": payload["relay"],
        "backend_pubkey": backend["pubkey"],
        "laptop_pubkey": payload["laptop_pubkey"],
        "pairing_id": payload["pairing_id"],
    }


def decode_pair_code(pair_code: str) -> dict[str, Any]:
    try:
        payload = json.loads(pair_code)
    except json.JSONDecodeError as error:
        raise WorktreeGuardError("Invalid pair code JSON.") from error
    if not isinstance(payload, dict):
        raise WorktreeGuardError("Invalid pair code.")
    if payload.get("version") != PAIR_CODE_VERSION or payload.get("product") != PRODUCT:
        raise WorktreeGuardError("Pair code is not for this WorktreeGuard version.")
    if int(payload.get("expires_at", 0)) <= int(time.time()):
        raise WorktreeGuardError("Pair code expired.")
    for key in ("relay", "laptop_pubkey", "pairing_id", "group_id", "secret"):
        if not isinstance(payload.get(key), str) or not payload[key]:
            raise WorktreeGuardError(f"Pair code is missing {key}.")
    return payload


def identity(state: dict[str, Any], name: str) -> dict[str, str]:
    remote = state.setdefault("remote", {})
    identities = remote.setdefault("identities", {})
    current = identities.get(name)
    if isinstance(current, dict) and current.get("secret") and current.get("pubkey"):
        if (
            os.environ.get("WTG_TRANSPORT", "nak").strip().lower() != "fake"
            and current.get("pubkey") == pubkey_for_secret(str(current["secret"]))
        ):
            current["pubkey"] = derive_pubkey(str(current["secret"]))
            if name == "backend":
                remote["backend"] = {
                    "nsec": str(current["secret"]),
                    "pubkey": str(current["pubkey"]),
                }
            save_state(state)
        return {"secret": str(current["secret"]), "pubkey": str(current["pubkey"])}
    secret = new_key_secret()
    current = {"secret": secret, "pubkey": derive_pubkey(secret)}
    identities[name] = current
    if name == "backend":
        remote["backend"] = {"nsec": secret, "pubkey": current["pubkey"]}
    save_state(state)
    return current


def derive_pubkey(secret: str) -> str:
    if os.environ.get("WTG_TRANSPORT", "nak").strip().lower() == "fake":
        return pubkey_for_secret(secret)
    binary = os.environ.get("WTG_NAK_BIN", "nak")
    if shutil.which(binary) is None:
        raise WorktreeGuardError("Remote approval requires `nak` or WTG_TRANSPORT=fake.")
    env = os.environ.copy()
    env["NOSTR_SECRET_KEY"] = secret
    try:
        result = subprocess.run(
            [binary, "event", "--kind", "1", "--content", ""],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
            env=env,
        )
    except subprocess.TimeoutExpired as error:
        raise WorktreeGuardError("Could not derive a Nostr identity: nak timed out.") from error
    if result.returncode == 0:
        from .remote_transport import NakTransport

        adapter = NakTransport(binary)
        for event in reversed(parse_events(result.stdout)):
            pubkey = str(event.get("pubkey") or "")
            if re.fullmatch(r"[0-9a-fA-F]{64}", pubkey) and adapter.verify(event):
                return pubkey.lower()
    detail = result.stderr.strip() if result.returncode else "invalid signed probe"
    raise WorktreeGuardError(f"Could not derive a Nostr identity with nak: {detail}")


def parse_events(raw: str) -> list[dict[str, Any]]:
    stripped = raw.strip()
    if not stripped:
        return []
    try:
        loaded = json.loads(stripped)
    except json.JSONDecodeError:
        loaded = None
    candidates = loaded if isinstance(loaded, list) else [loaded] if isinstance(loaded, dict) else []
    if not candidates:
        for line in stripped.splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                candidates.append(item)
    return [item for item in candidates if isinstance(item, dict)]


def publish_backend_metadata(secret: str, relay: str) -> None:
    event = signed_event(
        kind=0,
        secret=secret,
        content={"name": f"{socket.gethostname()} wtg daemon", "product": PRODUCT},
    )
    transport().publish(relay, event)


def publish_pairing_event(secret: str, payload: dict[str, Any]) -> None:
    event = signed_event(
        kind=PAIRING_KIND,
        secret=secret,
        tags=[
            ["p", payload["laptop_pubkey"]],
            ["h", payload["group_id"]],
            ["product", PRODUCT],
        ],
        content={
            "version": PAIR_CODE_VERSION,
            "product": PRODUCT,
            "pairing_id": payload["pairing_id"],
            "secret": payload["secret"],
            "hostname": socket.gethostname(),
        },
    )
    transport().publish(payload["relay"], event)


def valid_pairing_event(
    event: dict[str, Any],
    *,
    laptop_pubkey: str,
    offer: dict[str, Any],
    now: int,
) -> bool:
    if offer.get("used_at") is not None:
        return False
    if not structurally_valid_event(event):
        return False
    if int(offer.get("created_at", 0)) > int(event.get("created_at", 0)):
        return False
    if int(event.get("created_at", 0)) > int(offer.get("expires_at", 0)):
        return False
    if now > int(offer.get("expires_at", 0)):
        return False
    if not has_tag(event, "p", laptop_pubkey):
        return False
    if not has_tag(event, "h", str(offer.get("group_id") or "")):
        return False
    if not has_tag(event, "product", PRODUCT):
        return False
    from .remote_events import event_content

    payload = event_content(event)
    return (
        payload.get("version") == PAIR_CODE_VERSION
        and payload.get("product") == PRODUCT
        and payload.get("pairing_id") == offer.get("pairing_id")
        and payload.get("secret") == offer.get("secret")
    )


def pair_status() -> dict[str, Any]:
    state = load_state()
    remote = state.get("remote", {})
    backend = remote.get("backend", {})
    safe_backend = {"pubkey": backend.get("pubkey", "")} if isinstance(backend, dict) else {}
    offers = remote.get("pair_offers", {})
    safe_offers = {
        key: {field: value for field, value in offer.items() if field != "secret"}
        for key, offer in offers.items()
        if isinstance(offer, dict)
    } if isinstance(offers, dict) else {}
    return {
        "backend": safe_backend,
        "approved_peers": remote.get("approved_peers", {}),
        "pair_offers": safe_offers,
    }


def publish_group_event(
    secret: str,
    relay: str,
    kind: int,
    tags: list[list[str]],
) -> bool:
    """Try NIP-29 administration without requiring a NIP-29 relay."""
    event = signed_event(kind=kind, secret=secret, tags=tags, content={})
    try:
        transport().publish(relay, event)
    except WorktreeGuardError:
        return False
    return True


def revoke_peer(pubkey: str) -> bool:
    state = load_state()
    approved = state.setdefault("remote", {}).setdefault("approved_peers", {})
    existed = pubkey in approved
    approved.pop(pubkey, None)
    save_state(state)
    return existed

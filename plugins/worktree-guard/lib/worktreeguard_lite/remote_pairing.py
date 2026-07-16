"""Pairing state and commands for attended-laptop approval."""

from __future__ import annotations

import json
import os
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
    new_key_secret,
    new_secret,
    pubkey_for_secret,
    signed_event,
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
    state.setdefault("remote", {}).setdefault("pair_offers", {})[payload["pairing_id"]] = payload
    save_state(state)
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
    for key in ("relay", "laptop_pubkey", "pairing_id", "secret"):
        if not isinstance(payload.get(key), str) or not payload[key]:
            raise WorktreeGuardError(f"Pair code is missing {key}.")
    return payload


def identity(state: dict[str, Any], name: str) -> dict[str, str]:
    remote = state.setdefault("remote", {})
    identities = remote.setdefault("identities", {})
    current = identities.get(name)
    if isinstance(current, dict) and current.get("secret") and current.get("pubkey"):
        return {"secret": str(current["secret"]), "pubkey": str(current["pubkey"])}
    secret = new_key_secret()
    current = {"secret": secret, "pubkey": derive_pubkey(secret)}
    identities[name] = current
    if name == "backend":
        remote["backend"] = {"nsec": secret, "pubkey": current["pubkey"]}
    save_state(state)
    return current


def derive_pubkey(secret: str) -> str:
    binary = os.environ.get("WTG_NAK_BIN", "nak")
    if shutil.which(binary) is None:
        return pubkey_for_secret(secret)
    result = subprocess.run(
        [binary, "key", "public", secret],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=5,
        check=False,
    )
    pubkey = result.stdout.strip()
    if result.returncode == 0 and len(pubkey) >= 64:
        return pubkey[-64:]
    return pubkey_for_secret(secret)


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
        tags=[["p", payload["laptop_pubkey"]]],
        content={
            "product": PRODUCT,
            "pairing_id": payload["pairing_id"],
            "secret": payload["secret"],
            "hostname": socket.gethostname(),
        },
    )
    transport().publish(payload["relay"], event)


def pair_status() -> dict[str, Any]:
    state = load_state()
    remote = state.get("remote", {})
    return {
        "backend": remote.get("backend", {}),
        "approved_peers": remote.get("approved_peers", {}),
        "pair_offers": remote.get("pair_offers", {}),
    }


def revoke_peer(pubkey: str) -> bool:
    state = load_state()
    approved = state.setdefault("remote", {}).setdefault("approved_peers", {})
    existed = pubkey in approved
    approved.pop(pubkey, None)
    save_state(state)
    return existed

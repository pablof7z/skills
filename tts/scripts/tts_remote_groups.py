#!/usr/bin/env python3
"""NIP-29 lifecycle and membership helpers for the configured TTS channel."""

from __future__ import annotations

import os
import time

from tts_remote_signing import signed_event
from tts_remote_transport import transport


def request_group_creation(relay: str, group_id: str, laptop_nsec: str) -> str:
    return publish_management_event(relay, group_id, laptop_nsec, 9007, [], strict=False)


def request_group_membership(
    relay: str,
    group_id: str,
    laptop_nsec: str,
    pubkey: str,
) -> str:
    return publish_management_event(
        relay,
        group_id,
        laptop_nsec,
        9000,
        [["p", pubkey]],
    )


def request_group_admin(
    relay: str,
    group_id: str,
    nsec: str,
    pubkey: str,
) -> str:
    return publish_management_event(
        relay,
        group_id,
        nsec,
        9000,
        [["p", pubkey, "admin"]],
    )


def ensure_group_member(relay: str, group_id: str, admin_nsec: str, pubkey: str) -> str:
    tx = transport(relay)
    if pubkey in tx.group_members(group_id):
        return "present"
    request_group_membership(relay, group_id, admin_nsec, pubkey)
    wait_for_group_identity(tx.group_members, group_id, pubkey, "member")
    return "confirmed"


def wait_for_group_admin(relay: str, group_id: str, pubkey: str, on_wait=None) -> None:
    wait_for_group_identity(
        transport(relay).group_admins,
        group_id,
        pubkey,
        "admin",
        on_wait=on_wait,
    )


def wait_for_group_identity(reader, group_id: str, pubkey: str, role: str, on_wait=None) -> None:
    deadline = time.monotonic() + confirmation_timeout()
    while True:
        if pubkey in reader(group_id):
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(f"TTS channel did not confirm {role} {pubkey}")
        if on_wait is not None:
            on_wait()
        time.sleep(0.25)


def confirmation_timeout() -> float:
    try:
        return max(0.25, float(os.environ.get("TTS_GROUP_CONFIRM_TIMEOUT_SECONDS", "15")))
    except ValueError:
        return 15.0


def publish_management_event(
    relay: str,
    group_id: str,
    nsec: str,
    kind: int,
    extra_tags: list[list[str]],
    *,
    strict: bool = True,
) -> str:
    try:
        event = signed_event(
            kind=kind,
            content="",
            tags=[["h", group_id], *extra_tags],
            nsec=nsec,
            relay=relay,
        )
        transport(relay).publish(event)
    except RuntimeError:
        if strict:
            raise
        # Duplicate creation can be rejected when this signer already owns the
        # group. The caller confirms relay-authored admin state before use.
        return "unsupported"
    return "requested"

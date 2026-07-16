#!/usr/bin/env python3
"""Best-effort NIP-29 bootstrap for per-pair TTS groups."""

from __future__ import annotations

from tts_remote_signing import signed_event
from tts_remote_transport import transport


def request_group_creation(relay: str, group_id: str, laptop_nsec: str) -> str:
    return publish_management_event(relay, group_id, laptop_nsec, 9007, [])


def request_group_membership(
    relay: str,
    group_id: str,
    laptop_nsec: str,
    backend_pubkey: str,
) -> str:
    return publish_management_event(
        relay,
        group_id,
        laptop_nsec,
        9000,
        [["p", backend_pubkey]],
    )


def publish_management_event(
    relay: str,
    group_id: str,
    nsec: str,
    kind: int,
    extra_tags: list[list[str]],
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
        # Ordinary relays may not implement NIP-29 management kinds. The same
        # h-scoped, p-targeted request flow remains safe and usable there.
        return "unsupported"
    return "requested"

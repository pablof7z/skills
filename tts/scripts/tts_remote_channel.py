#!/usr/bin/env python3
"""Parse the NIP-29 relay/group coordinate carried by pairing tokens."""

from __future__ import annotations

import re
from urllib.parse import urlsplit


DEFAULT_PAIRING_RELAY = "wss://relay.primal.net"
DEFAULT_CHANNEL = "wss://nip29.f7z.io/tts"


def channel_parts(channel: str, fallback_relay: str | None = None) -> tuple[str, str]:
    parsed = urlsplit(channel)
    if parsed.scheme in {"ws", "wss"} and parsed.netloc:
        group_id = parsed.path.strip("/")
        relay = f"{parsed.scheme}://{parsed.netloc}"
    elif fallback_relay and re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", channel):
        relay = fallback_relay
        group_id = channel
    else:
        raise RuntimeError("TTS channel must look like wss://nip29.example/tts")
    if not re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", group_id):
        raise RuntimeError("TTS channel group id is invalid")
    return relay, group_id

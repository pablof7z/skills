#!/usr/bin/env python3
"""Compact, role-neutral pairing tokens for remote TTS."""

from __future__ import annotations

import base64
import hashlib
import re
import struct
from typing import Mapping


PREFIX = "ttspair1_"
PAIRING_KIND = 24133
FIELDS = frozenset({"peer", "secret", "relay", "channel"})
MAX_TOKEN_BYTES = 2048


class PairTokenError(ValueError):
    """The supplied pairing token is malformed or unsupported."""


def encode_pair_token(value: Mapping[str, object]) -> str:
    payload = validated_payload(value)
    peer = bytes.fromhex(payload["peer"])
    values = [payload[name].encode("utf-8") for name in ("secret", "relay", "channel")]
    raw = peer + struct.pack(">HHH", *(len(item) for item in values)) + b"".join(values)
    encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    return PREFIX + encoded


def decode_pair_token(token: str) -> dict[str, str]:
    if not isinstance(token, str) or not token.startswith(PREFIX):
        raise PairTokenError("pair code is not a supported TTS token")
    encoded = token[len(PREFIX):]
    if not encoded or len(encoded) > 4096 or not re.fullmatch(r"[A-Za-z0-9_-]+", encoded):
        raise PairTokenError("pair code is malformed")
    try:
        raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        if len(raw) < 38 or len(raw) > MAX_TOKEN_BYTES:
            raise PairTokenError("pair code payload is invalid")
        lengths = struct.unpack(">HHH", raw[32:38])
        if 38 + sum(lengths) != len(raw):
            raise PairTokenError("pair code payload is invalid")
        offset = 38
        values = []
        for length in lengths:
            values.append(raw[offset:offset + length].decode("utf-8"))
            offset += length
        loaded = {
            "peer": raw[:32].hex(),
            "secret": values[0],
            "relay": values[1],
            "channel": values[2],
        }
    except (ValueError, UnicodeError, struct.error) as error:
        raise PairTokenError("pair code is malformed") from error
    return validated_payload(loaded)


def validated_payload(value: Mapping[str, object]) -> dict[str, str]:
    if set(value) != FIELDS:
        raise PairTokenError("pair code must contain peer, secret, relay, and channel")
    payload = {key: value[key] for key in sorted(FIELDS)}
    if any(not isinstance(item, str) or not item.strip() for item in payload.values()):
        raise PairTokenError("pair code fields must be non-empty strings")
    peer = str(payload["peer"])
    secret = str(payload["secret"])
    relay = str(payload["relay"])
    channel = str(payload["channel"])
    if not re.fullmatch(r"[0-9a-fA-F]{64}", peer):
        raise PairTokenError("pair code peer must be a Nostr pubkey")
    if len(secret) < 16 or len(secret) > 256:
        raise PairTokenError("pair code secret has an invalid length")
    if not re.fullmatch(r"(?:wss?|file)://[^\s]{1,500}", relay):
        raise PairTokenError("pair code relay must be a WebSocket relay URL")
    if not re.fullmatch(r"wss?://[^\s/]+/[A-Za-z0-9._:-]{1,128}", channel):
        raise PairTokenError("pair code channel must identify a NIP-29 relay and group")
    return {"peer": peer.lower(), "secret": secret, "relay": relay, "channel": channel}


def pairing_key(secret: str) -> str:
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()

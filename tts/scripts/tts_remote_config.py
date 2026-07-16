#!/usr/bin/env python3
"""User-owned relay and channel configuration for remote TTS."""

from __future__ import annotations

import os

from tts_pair_token import PairTokenError, validated_payload
from tts_remote_channel import DEFAULT_CHANNEL, DEFAULT_PAIRING_RELAY, channel_parts
from tts_remote_state import read_json, remote_dir, write_json


DEFAULT_RELAY = DEFAULT_PAIRING_RELAY


def remote_config() -> dict[str, str]:
    loaded = read_json(remote_dir() / "config.json", {})
    relay = str(loaded.get("relay") or os.environ.get("TTS_REMOTE_RELAY") or DEFAULT_RELAY)
    channel = str(loaded.get("channel") or os.environ.get("TTS_REMOTE_CHANNEL") or DEFAULT_CHANNEL)
    validate_coordinate(relay, channel)
    return {"relay": relay, "channel": channel}


def save_remote_config(relay: str, channel: str) -> dict[str, str]:
    validate_coordinate(relay, channel)
    value = {"relay": relay, "channel": channel}
    write_json(remote_dir() / "config.json", value)
    return value


def validate_coordinate(relay: str, channel: str) -> None:
    try:
        validated_payload({
            "peer": "0" * 64,
            "secret": "configuration-check",
            "relay": relay,
            "channel": channel,
        })
    except PairTokenError as error:
        raise RuntimeError(str(error)) from error
    channel_parts(channel)

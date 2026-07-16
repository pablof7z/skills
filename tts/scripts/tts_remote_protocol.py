#!/usr/bin/env python3
"""Human-readable Nostr protocol helpers for remote TTS."""

from __future__ import annotations

import json
import re


MAX_REMOTE_ASK_SECONDS = 3600


def request_tags(
    *,
    peer_pubkey: str,
    group_id: str,
    backend_pubkey: str,
    request_id: str,
    subject: str,
    agent_name: str,
    attachments: list[dict[str, str]],
    ask: str | None = None,
    wait: str | None = None,
) -> list[list[str]]:
    tags = [
        ["p", peer_pubkey],
        ["h", group_id],
        ["product", "tts"],
        ["request", request_id],
        ["reply", backend_pubkey],
        ["subject", subject],
        ["agent", agent_name],
    ]
    tags.extend(["attachment", item["path"], item["label"]] for item in attachments)
    if ask:
        tags.extend([["ask", ask], ["wait", str(wait)]])
    return tags


def request_payload(event: dict[str, object]) -> dict[str, object] | None:
    request_id = tag_value(event, "request")
    message = event.get("content")
    attachments = attachment_values(event)
    if not request_id or not isinstance(message, str) or not message.strip() or attachments is None:
        return None
    result: dict[str, object] = {
        "request_id": request_id,
        "message": message,
        "subject": tag_value(event, "subject") or "Remote TTS request from paired host",
        "agent_name": tag_value(event, "agent") or "remote",
        "attachments": attachments,
    }
    ask = tag_value(event, "ask")
    wait = tag_value(event, "wait")
    if bool(ask) != bool(wait):
        return None
    if ask:
        try:
            bundle = json.loads(ask)
        except ValueError:
            return None
        if not isinstance(bundle, dict) or not wait:
            return None
        try:
            duration_seconds(wait)
        except RuntimeError:
            return None
        result.update({"ask": ask, "wait": wait})
    return result


def reply_tags(
    event: dict[str, object],
    status: str,
    *,
    error_code: str | None = None,
    guidance: str | None = None,
    response: dict[str, object] | None = None,
) -> list[list[str]]:
    tags = [
        ["e", str(event.get("id") or "")],
        ["p", tag_value(event, "reply") or str(event.get("pubkey") or "")],
        ["h", tag_value(event, "h") or ""],
        ["product", "tts"],
        ["request", tag_value(event, "request") or ""],
        ["status", status],
    ]
    if error_code:
        tags.append(["error", error_code])
    if guidance:
        tags.append(["guidance", guidance])
    if response:
        tags.append(["response", json.dumps(response, ensure_ascii=False, sort_keys=True, separators=(",", ":"))])
    return tags


def tag_value(event: dict[str, object], name: str) -> str | None:
    tags = event.get("tags")
    if not isinstance(tags, list):
        return None
    for tag in tags:
        if isinstance(tag, list) and len(tag) >= 2 and tag[0] == name:
            return str(tag[1])
    return None


def attachment_values(event: dict[str, object]) -> list[dict[str, str]] | None:
    tags = event.get("tags")
    if not isinstance(tags, list):
        return None
    result = []
    for tag in tags:
        if not isinstance(tag, list) or not tag or tag[0] != "attachment":
            continue
        if len(tag) != 3 or not all(isinstance(value, str) and value for value in tag[1:]):
            return None
        result.append({"path": tag[1], "label": tag[2]})
    return result


def duration_seconds(value: str) -> float:
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smh]?)", value.strip(), re.IGNORECASE)
    if not match or float(match.group(1)) <= 0:
        raise RuntimeError("--wait requires a positive duration such as 30s, 5m, or 1h")
    seconds = float(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2).lower()]
    if seconds > MAX_REMOTE_ASK_SECONDS:
        raise RuntimeError("remote --wait cannot exceed 1h")
    return seconds

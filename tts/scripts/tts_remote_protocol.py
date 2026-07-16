#!/usr/bin/env python3
"""Human-readable Nostr protocol helpers for remote TTS."""

from __future__ import annotations


def request_tags(
    *,
    peer_pubkey: str,
    group_id: str,
    backend_pubkey: str,
    request_id: str,
    subject: str,
    agent_name: str,
    attachments: list[dict[str, str]],
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
    return tags


def request_payload(event: dict[str, object]) -> dict[str, object] | None:
    request_id = tag_value(event, "request")
    message = event.get("content")
    attachments = attachment_values(event)
    if not request_id or not isinstance(message, str) or not message.strip() or attachments is None:
        return None
    return {
        "request_id": request_id,
        "message": message,
        "subject": tag_value(event, "subject") or "Remote TTS request from paired host",
        "agent_name": tag_value(event, "agent") or "remote",
        "attachments": attachments,
    }


def reply_tags(
    event: dict[str, object],
    status: str,
    *,
    error_code: str | None = None,
    guidance: str | None = None,
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

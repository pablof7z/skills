#!/usr/bin/env python3
"""Blocking ask round trips for paired remote TTS agents."""

from __future__ import annotations

import json
import os
from pathlib import Path
import time

from tts_remote_protocol import duration_seconds, tag_value
from tts_remote_signing import verify_event
from tts_remote_transport import transport


def prepare_ask(source: str | None, wait: str | None) -> str | None:
    if not source:
        if wait:
            raise RuntimeError("--wait may only be used with --ask")
        return None
    if not wait:
        raise RuntimeError("--ask requires --wait with a positive duration")
    duration_seconds(wait)
    try:
        raw = Path(source[1:]).expanduser().read_text(encoding="utf-8") if source.startswith("@") else source
        value = json.loads(raw)
    except (OSError, ValueError) as error:
        raise RuntimeError(f"invalid remote ask: {error}") from error
    if not isinstance(value, dict) or not isinstance(value.get("questions"), list) or not value["questions"]:
        raise RuntimeError("remote ask requires a non-empty questions array")
    if contains_attachments(value):
        raise RuntimeError("remote ask attachments are not supported because laptop paths are private")
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > 32_000:
        raise RuntimeError("remote ask bundle cannot exceed 32 KB")
    return encoded


def wait_for_answer(
    *,
    request_event: dict[str, object],
    backend_pubkey: str,
    laptop_pubkey: str,
    relay: str,
    group_id: str,
    wait: str,
) -> dict[str, object]:
    request_id = tag_value(request_event, "request") or ""
    grace = float(os.environ.get("TTS_REMOTE_ASK_DELIVERY_SECONDS", "120"))
    deadline = time.monotonic() + duration_seconds(wait) + max(1.0, grace)
    since = max(0, int(request_event.get("created_at") or 0) - 1)
    while time.monotonic() < deadline:
        events = transport(relay).events(
            target_pubkey=backend_pubkey,
            group_ids=[group_id],
            since=since,
            kinds=[9],
        )
        for event in events:
            if valid_answer(event, request_event, request_id, laptop_pubkey):
                return answer_result(event, request_event)
        time.sleep(min(0.5, max(0.0, deadline - time.monotonic())))
    return {
        "status": "pending",
        "request_id": request_id,
        "event_id": request_event.get("id"),
        "guidance": "The user has not answered yet. Retry the ask if their answer is still required.",
    }


def valid_answer(
    event: dict[str, object],
    request_event: dict[str, object],
    request_id: str,
    laptop_pubkey: str,
) -> bool:
    return (
        event.get("pubkey") == laptop_pubkey
        and tag_value(event, "e") == request_event.get("id")
        and tag_value(event, "request") == request_id
        and tag_value(event, "product") == "tts"
        and bool(tag_value(event, "status"))
        and verify_event(event)
    )


def answer_result(event: dict[str, object], request_event: dict[str, object]) -> dict[str, object]:
    result: dict[str, object] = {
        "status": tag_value(event, "status"),
        "request_id": tag_value(event, "request"),
        "event_id": request_event.get("id"),
        "reply_event_id": event.get("id"),
    }
    encoded = tag_value(event, "response")
    if encoded:
        try:
            response = json.loads(encoded)
        except ValueError:
            response = None
        if isinstance(response, dict):
            result["response"] = response
    for key in ("error", "guidance"):
        value = tag_value(event, key)
        if value:
            result[key] = value
    return result


def safe_response(value: dict[str, object]) -> dict[str, object]:
    result: dict[str, object] = {"status": value.get("status")}
    questions = value.get("questions")
    if isinstance(questions, list):
        result["questions"] = [safe_question(item) for item in questions if isinstance(item, dict)]
    else:
        result.update(safe_answer_fields(value))
    return result


def safe_question(question: dict[str, object]) -> dict[str, object]:
    result = {"id": question.get("id"), "status": question.get("status")}
    response = question.get("response")
    if isinstance(response, dict):
        result["response"] = safe_answer_fields(response)
    return result


def safe_answer_fields(value: dict[str, object]) -> dict[str, object]:
    return {
        key: value.get(key)
        for key in ("answer", "suggestion_id", "suggestion_ids", "modified", "interaction")
        if value.get(key) is not None
    }


def contains_attachments(value: object) -> bool:
    if isinstance(value, dict):
        return bool(value.get("attachments")) or any(contains_attachments(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_attachments(item) for item in value)
    return False


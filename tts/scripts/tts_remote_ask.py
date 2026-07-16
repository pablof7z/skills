#!/usr/bin/env python3
"""Blocking ask round trips for paired remote TTS agents."""

from __future__ import annotations

import json
import os
from pathlib import Path
import time

from tts_remote_protocol import answer_values, duration_seconds, tag_rows, tag_value
from tts_remote_signing import verify_event
from tts_remote_transport import transport


def prepare_ask(source: str | None, wait: str | None) -> dict[str, object] | None:
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
    if contains_attachments(value):
        raise RuntimeError("remote ask attachments are not supported because laptop paths are private")
    normalized = normalize_ask(value)
    if len(json.dumps(normalized, ensure_ascii=False).encode("utf-8")) > 32_000:
        raise RuntimeError("remote ask bundle cannot exceed 32 KB")
    return normalized


def normalize_ask(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not isinstance(value.get("questions"), list) or not value["questions"]:
        raise RuntimeError("remote ask requires a non-empty questions array")
    questions = []
    for index, raw_question in enumerate(value["questions"], 1):
        if not isinstance(raw_question, dict):
            raise RuntimeError(f"remote ask question {index} must be an object")
        title = required_text(raw_question.get("title"), f"question {index} title")
        short_title = optional_text(raw_question.get("short_title")) or title
        question_type = raw_question.get("type", "single_choice")
        if question_type not in {"single_choice", "multiple_choice"}:
            raise RuntimeError(f"remote ask question {index} has an invalid type")
        raw_suggestions = raw_question.get("suggestions") or []
        if not isinstance(raw_suggestions, list):
            raise RuntimeError(f"remote ask question {index} suggestions must be an array")
        suggestions = []
        for option_index, raw_option in enumerate(raw_suggestions, 1):
            if not isinstance(raw_option, dict):
                raise RuntimeError(f"remote ask question {index} option {option_index} must be an object")
            suggestions.append({
                "title": required_text(raw_option.get("title"), f"question {index} option {option_index} title"),
                "description": optional_text(raw_option.get("description")),
                "attachments": raw_option.get("attachments") or [],
            })
        questions.append({
            "id": f"q-{index:02d}",
            "short_title": short_title,
            "title": title,
            "type": question_type,
            "description": optional_text(raw_question.get("description")),
            "attachments": raw_question.get("attachments") or [],
            "suggestions": suggestions,
        })
    return {
        "questions_preamble": optional_text(value.get("questions_preamble")),
        "questions": questions,
    }


def required_text(value: object, field: str) -> str:
    text = optional_text(value)
    if not text:
        raise RuntimeError(f"remote ask {field} must be a non-empty string")
    return text


def optional_text(value: object) -> str | None:
    return value.strip() or None if isinstance(value, str) else None


def wait_for_answer(
    *,
    request_event: dict[str, object],
    relay: str,
    wait: str,
) -> dict[str, object]:
    request_id = str(request_event.get("id") or "")
    recipient_pubkey = str(request_event.get("pubkey") or "")
    laptop_pubkey = tag_value(request_event, "p") or ""
    group_id = tag_value(request_event, "h") or ""
    if not all((request_id, recipient_pubkey, laptop_pubkey, group_id)):
        raise RuntimeError("remote ask request is missing signed routing fields")
    grace = float(os.environ.get("TTS_REMOTE_ASK_DELIVERY_SECONDS", "120"))
    deadline = time.monotonic() + duration_seconds(wait) + max(1.0, grace)
    since = max(0, int(request_event.get("created_at") or 0) - 1)
    while time.monotonic() < deadline:
        events = transport(relay).events(
            target_pubkey=recipient_pubkey,
            group_ids=[group_id],
            since=since,
            kinds=[9],
            referenced_event_id=request_id,
        )
        for event in events:
            if valid_answer(event, request_event):
                return answer_result(event, request_event)
        time.sleep(min(0.5, max(0.0, deadline - time.monotonic())))
    return {
        "status": "pending",
        "event_id": request_event.get("id"),
        "guidance": "The user has not answered yet. Retry the ask if their answer is still required.",
    }


def valid_answer(
    event: dict[str, object],
    request_event: dict[str, object],
) -> bool:
    recipient_pubkey = str(request_event.get("pubkey") or "")
    laptop_pubkey = tag_value(request_event, "p") or ""
    group_id = tag_value(request_event, "h") or ""
    answers = answer_values(event)
    question_ids = {row[1] for row in tag_rows(request_event, "question") if len(row) == 4}
    return (
        event.get("pubkey") == laptop_pubkey
        and tag_value(event, "e") == request_event.get("id")
        and tag_value(event, "p") == recipient_pubkey
        and tag_value(event, "h") == group_id
        and answers is not None
        and all(question_id in question_ids for question_id, _values in answers)
        and verify_event(event)
    )


def answer_result(event: dict[str, object], request_event: dict[str, object]) -> dict[str, object]:
    answers = answer_values(event) or []
    error = tag_value(event, "error")
    result: dict[str, object] = {
        "status": "rejected" if error else "answered" if answers else "skipped",
        "event_id": request_event.get("id"),
        "answers": [
            {"id": question_id, "values": values}
            for question_id, values in answers
        ],
    }
    if error:
        result.update({"error": error, "message": event.get("content")})
    return result


def answers_from_result(
    result: dict[str, object],
    request_event: dict[str, object],
) -> list[tuple[str, list[str]]]:
    options = options_by_question(request_event)
    answers = []
    for question in result.get("questions") or []:
        if not isinstance(question, dict) or question.get("status") != "answered":
            continue
        response = question.get("response")
        if not isinstance(response, dict):
            continue
        question_id = str(question.get("id") or "")
        values = selected_titles(response)
        if not values:
            values = selected_option_titles(response, options.get(question_id, []))
        answer = optional_text(response.get("answer"))
        if answer and (not values or answer != ", ".join(values)):
            values.append(answer)
        if question_id and values:
            answers.append((question_id, values))
    return answers


def selected_titles(response: dict[str, object]) -> list[str]:
    selected = response.get("selected_suggestions")
    if not isinstance(selected, list):
        return []
    return [
        title
        for item in selected
        if isinstance(item, dict) and (title := optional_text(item.get("title")))
    ]


def selected_option_titles(response: dict[str, object], options: list[str]) -> list[str]:
    identifiers = response.get("suggestion_ids")
    if not isinstance(identifiers, list):
        return []
    result = []
    for identifier in identifiers:
        match = re_option_id(str(identifier))
        if match is not None and match < len(options):
            result.append(options[match])
    return result


def re_option_id(identifier: str) -> int | None:
    try:
        return int(identifier.rsplit("-s-", 1)[1]) - 1
    except (IndexError, ValueError):
        return None


def options_by_question(event: dict[str, object]) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    for row in tag_rows(event, "option"):
        if len(row) >= 3:
            result.setdefault(row[1], []).append(row[2])
    return result


def contains_attachments(value: object) -> bool:
    if isinstance(value, dict):
        return bool(value.get("attachments")) or any(contains_attachments(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_attachments(item) for item in value)
    return False

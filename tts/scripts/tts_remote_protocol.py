#!/usr/bin/env python3
"""Readable native Nostr messages for paired TTS."""

from __future__ import annotations

import json
import re


MAX_REMOTE_ASK_SECONDS = 3600
LEGACY_WIRE_TAGS = {"ask", "product", "request", "reply", "response", "status", "subject"}


def request_tags(
    *,
    peer_pubkey: str,
    group_id: str,
    title: str,
    agent_name: str,
    message: str,
    attachments: list[dict[str, str]],
    ask: dict[str, object] | None = None,
    wait: str | None = None,
) -> list[list[str]]:
    tags = [
        ["p", peer_pubkey],
        ["h", group_id],
        ["title", title],
        ["agent", agent_name],
    ]
    tags.extend(["attachment", item["path"], item["label"]] for item in attachments)
    if not ask:
        return tags
    tags.append(["message", message])
    preamble = ask.get("questions_preamble")
    if isinstance(preamble, str) and preamble:
        tags.append(["preamble", preamble])
    for question in ask["questions"]:
        question_id = str(question["id"])
        question_type = "multiple" if question.get("type") == "multiple_choice" else "single"
        tags.append(["question", question_id, question_type, str(question["title"])])
        short_title = str(question.get("short_title") or "")
        if short_title and short_title != question["title"]:
            tags.append(["label", question_id, short_title])
        description = question.get("description")
        if isinstance(description, str) and description:
            tags.append(["description", question_id, description])
        for option in question.get("suggestions") or []:
            option_tag = ["option", question_id, str(option["title"])]
            option_description = option.get("description")
            if isinstance(option_description, str) and option_description:
                option_tag.append(option_description)
            tags.append(option_tag)
    tags.append(["wait", str(wait)])
    return tags


def render_request_content(tags: list[list[str]]) -> str:
    event: dict[str, object] = {"tags": tags}
    title = unique_tag_value(event, "title") or "Question"
    message = unique_tag_value(event, "message") or ""
    questions = parse_questions(event) or []
    parts = [f"# {title}"]
    duplicate_single_question = len(questions) == 1 and message.strip() == str(questions[0]["title"]).strip()
    if message.strip() and not duplicate_single_question:
        parts.extend(["", message.strip()])
    preamble = unique_tag_value(event, "preamble")
    if isinstance(preamble, str) and preamble.strip():
        parts.extend(["", preamble.strip()])
    for index, question in enumerate(questions, 1):
        parts.extend(["", f"{index}. **{question['title']}**"])
        description = question.get("description")
        if isinstance(description, str) and description:
            parts.append(f"   {description}")
        for option in question.get("suggestions") or []:
            line = f"   - [ ] {option['title']}"
            option_description = option.get("description")
            if isinstance(option_description, str) and option_description:
                line += f" — {option_description}"
            parts.append(line)
    return "\n".join(parts)


def request_payload(event: dict[str, object]) -> dict[str, object] | None:
    content = event.get("content")
    tags = event.get("tags")
    attachments = attachment_values(event)
    if (
        not isinstance(content, str)
        or not content.strip()
        or not isinstance(tags, list)
        or attachments is None
        or any(tag_value(event, name) is not None for name in LEGACY_WIRE_TAGS)
    ):
        return None
    title = unique_tag_value(event, "title")
    agent_name = unique_tag_value(event, "agent")
    if not title or not agent_name:
        return None
    questions = parse_questions(event)
    wait = unique_tag_value(event, "wait")
    if questions is None or bool(questions) != bool(wait):
        return None
    action_rows = tag_rows(event, "action")
    action = action_rows[0][1] if len(action_rows) == 1 and len(action_rows[0]) == 2 else None
    if action_rows and action != "generate":
        return None
    if action == "generate" and questions:
        return None
    result: dict[str, object] = {
        "message": content,
        "subject": title,
        "agent_name": agent_name,
        "attachments": attachments,
        "action": action or "speak",
    }
    if not questions:
        return result
    try:
        duration_seconds(str(wait))
    except RuntimeError:
        return None
    message = unique_tag_value(event, "message")
    preamble = unique_tag_value(event, "preamble")
    if message is None:
        return None
    bundle = {"questions_preamble": preamble, "questions": questions}
    result.update({
        "message": message,
        "ask": json.dumps(bundle, ensure_ascii=False, separators=(",", ":")),
        "wait": wait,
    })
    return result


def parse_questions(event: dict[str, object]) -> list[dict[str, object]] | None:
    rows = tag_rows(event, "question")
    if not rows:
        return []
    questions: list[dict[str, object]] = []
    by_id: dict[str, dict[str, object]] = {}
    for row in rows:
        if len(row) != 4 or row[1] in by_id or row[2] not in {"single", "multiple"} or not row[3]:
            return None
        question = {
            "short_title": row[3],
            "title": row[3],
            "type": "multiple_choice" if row[2] == "multiple" else "single_choice",
            "description": None,
            "attachments": [],
            "suggestions": [],
        }
        questions.append(question)
        by_id[row[1]] = question
    if not apply_question_text_tags(event, "label", "short_title", by_id):
        return None
    if not apply_question_text_tags(event, "description", "description", by_id):
        return None
    for row in tag_rows(event, "option"):
        if len(row) not in {3, 4} or row[1] not in by_id or not row[2]:
            return None
        by_id[row[1]]["suggestions"].append({
            "title": row[2],
            "description": row[3] if len(row) == 4 and row[3] else None,
            "attachments": [],
        })
    return questions


def apply_question_text_tags(
    event: dict[str, object],
    tag_name: str,
    field: str,
    questions: dict[str, dict[str, object]],
) -> bool:
    seen: set[str] = set()
    for row in tag_rows(event, tag_name):
        if len(row) != 3 or row[1] not in questions or row[1] in seen or not row[2]:
            return False
        questions[row[1]][field] = row[2]
        seen.add(row[1])
    return True


def reply_tags(
    event: dict[str, object],
    *,
    answers: list[tuple[str, list[str]]] | None = None,
    error_code: str | None = None,
) -> list[list[str]]:
    tags = [
        ["e", str(event.get("id") or "")],
        ["p", str(event.get("pubkey") or "")],
        ["h", tag_value(event, "h") or ""],
    ]
    tags.extend(["answer", question_id, *values] for question_id, values in answers or [])
    if error_code:
        tags.append(["error", error_code])
    return tags


def render_reply_content(event: dict[str, object], tags: list[list[str]]) -> str:
    titles = {
        row[1]: row[3]
        for row in tag_rows(event, "question")
        if len(row) == 4
    }
    answers = answer_values({"tags": tags}) or []
    lines = ["# User has replied", ""]
    for index, (question_id, values) in enumerate(answers, 1):
        title = titles.get(question_id, question_id)
        lines.append(f"{index}. **{title}** {', '.join(values)}")
    if not answers:
        lines.extend(["", "No answers were provided."])
    return "\n".join(lines)


def answer_values(event: dict[str, object]) -> list[tuple[str, list[str]]] | None:
    result = []
    seen: set[str] = set()
    for row in tag_rows(event, "answer"):
        if len(row) < 3 or row[1] in seen or any(not value for value in row[2:]):
            return None
        result.append((row[1], row[2:]))
        seen.add(row[1])
    return result


def tag_rows(event: dict[str, object], name: str) -> list[list[str]]:
    tags = event.get("tags")
    if not isinstance(tags, list):
        return []
    return [
        [str(value) for value in tag]
        for tag in tags
        if isinstance(tag, list) and tag and tag[0] == name
    ]


def tag_value(event: dict[str, object], name: str) -> str | None:
    rows = tag_rows(event, name)
    return rows[0][1] if rows and len(rows[0]) >= 2 else None


def unique_tag_value(event: dict[str, object], name: str) -> str | None:
    rows = tag_rows(event, name)
    if len(rows) != 1 or len(rows[0]) != 2 or not rows[0][1]:
        return None
    return rows[0][1]


def attachment_values(event: dict[str, object]) -> list[dict[str, str]] | None:
    result = []
    for row in tag_rows(event, "attachment"):
        if len(row) != 3 or not row[1] or not row[2]:
            return None
        result.append({"path": row[1], "label": row[2]})
    return result


def duration_seconds(value: str) -> float:
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smh]?)", value.strip(), re.IGNORECASE)
    if not match or float(match.group(1)) <= 0:
        raise RuntimeError("--wait requires a positive duration such as 30s, 5m, or 1h")
    seconds = float(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2).lower()]
    if seconds > MAX_REMOTE_ASK_SECONDS:
        raise RuntimeError("remote --wait cannot exceed 1h")
    return seconds

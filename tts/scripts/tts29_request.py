"""Pure request shaping for the standalone TTS29 producer adapter."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
from typing import Any


VOICES = (
    "af_bella",
    "af_heart",
    "af_kore",
    "af_nova",
    "af_sarah",
    "am_michael",
    "am_puck",
)
REQUEST_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class RequestError(ValueError):
    """The requested skill invocation cannot form a valid TTS29 request."""


def parse_duration(value: str) -> int:
    match = re.fullmatch(r"([0-9]+)([smh]?)", value.strip(), re.IGNORECASE)
    if not match:
        raise RequestError("--wait must be a positive duration such as 30s or 5m")
    amount = int(match.group(1))
    multiplier = {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2).lower()]
    seconds = amount * multiplier
    if not 1 <= seconds <= 300:
        raise RequestError("--wait must be between 1 second and 5 minutes")
    return seconds


def select_voice(agent_name: str) -> str:
    digest = hashlib.sha256(agent_name.encode()).digest()
    return VOICES[int.from_bytes(digest[:4], "big") % len(VOICES)]


def load_json(source: str, label: str) -> Any:
    try:
        if source.startswith("@"):
            path = Path(source[1:]).expanduser()
            if not path.is_file():
                raise RequestError(f"{label} file does not exist: {path}")
            if path.stat().st_size > 128 * 1024:
                raise RequestError(f"{label} file exceeds 128 KiB")
            return json.loads(path.read_text(encoding="utf-8"))
        return json.loads(source)
    except json.JSONDecodeError as error:
        raise RequestError(f"{label} is invalid JSON: {error.msg}") from error
    except OSError as error:
        raise RequestError(f"{label} file could not be read: {error}") from error


def _text(value: Any, label: str, maximum: int, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value.strip():
        if optional and isinstance(value, str):
            return None
        raise RequestError(f"{label} must be a non-empty string")
    result = value.strip()
    if len(result.encode("utf-8")) > maximum:
        raise RequestError(f"{label} must not exceed {maximum} UTF-8 bytes")
    return result


def _options(raw: Any, question_id: str) -> list[dict[str, Any]]:
    if raw is None:
        return []
    if not isinstance(raw, list) or len(raw) > 8:
        raise RequestError(f"{question_id} suggestions must be an array of at most 8 items")
    result = []
    for index, entry in enumerate(raw, 1):
        if isinstance(entry, list) and len(entry) == 2:
            entry = {"title": entry[0], "description": entry[1]}
        if not isinstance(entry, dict):
            raise RequestError(f"{question_id} suggestion {index} must be an object")
        unknown = set(entry) - {"title", "description"}
        if unknown:
            raise RequestError(f"{question_id} suggestion {index} has unsupported fields")
        result.append(
            {
                "id": f"{question_id}-o{index}",
                "title": _text(entry.get("title"), "suggestion title", 120),
                "description": _text(
                    entry.get("description"), "suggestion description", 300, optional=True
                ),
            }
        )
    return result


def build_questions(
    ask: str | None,
    suggestions: str | None,
    message: str,
    subject: str,
) -> tuple[list[dict[str, Any]], str | None]:
    if ask is None:
        if suggestions is not None:
            raise RequestError("--suggestions requires --ask")
        return [], None
    if ask == "":
        options = _options(load_json(suggestions, "--suggestions") if suggestions else [], "q1")
        title = _text(message, "bare question message", 240)
        return [
            {
                "id": "q1",
                "kind": "single_choice" if options else "freeform",
                "short_title": subject if len(subject) <= 40 else "Question",
                "title": title,
                "description": None,
                "options": options,
            }
        ], None
    if suggestions is not None:
        raise RequestError("put suggestions inside each structured --ask question")

    root = load_json(ask, "--ask")
    if not isinstance(root, dict) or set(root) - {"questions_preamble", "questions"}:
        raise RequestError("structured --ask must contain only questions_preamble and questions")
    preamble = _text(root.get("questions_preamble"), "questions_preamble", 500, optional=True)
    raw_questions = root.get("questions")
    if not isinstance(raw_questions, list) or not 1 <= len(raw_questions) <= 3:
        raise RequestError("structured --ask requires between 1 and 3 questions")
    questions = []
    allowed = {"short_title", "title", "description", "type", "suggestions"}
    for index, raw in enumerate(raw_questions, 1):
        if not isinstance(raw, dict) or set(raw) - allowed:
            raise RequestError(f"question {index} has unsupported fields")
        question_id = f"q{index}"
        kind = raw.get("type", "single_choice")
        if kind not in {"single_choice", "multiple_choice", "freeform"}:
            raise RequestError(f"question {index} type is unsupported")
        options = _options(raw.get("suggestions", []), question_id)
        if (kind == "freeform") == bool(options):
            raise RequestError(
                f"question {index} must use suggestions exactly when it is a choice question"
            )
        questions.append(
            {
                "id": question_id,
                "kind": kind,
                "short_title": _text(raw.get("short_title"), "question short_title", 40),
                "title": _text(raw.get("title"), "question title", 240),
                "description": _text(
                    raw.get("description"), "question description", 500, optional=True
                ),
                "options": options,
            }
        )
    return questions, preamble


def build_artifacts(sources: list[str]) -> list[dict[str, Any]]:
    result = []
    required = {"url", "sha256", "media_type", "byte_count", "label"}
    for index, source in enumerate(sources, 1):
        value = load_json(source, f"--artifact {index}")
        if not isinstance(value, dict) or set(value) != required:
            raise RequestError(f"--artifact {index} must contain exactly {sorted(required)}")
        url = _text(value["url"], "artifact url", 2048)
        digest = _text(value["sha256"], "artifact sha256", 64)
        media_type = _text(value["media_type"], "artifact media_type", 128)
        label = _text(value["label"], "artifact label", 120)
        byte_count = value["byte_count"]
        if not url.startswith("https://") or not SHA256.fullmatch(digest):
            raise RequestError(f"--artifact {index} requires an HTTPS URL and lowercase SHA-256")
        valid_count = type(byte_count) is int and 1 <= byte_count <= 250 * 1024 * 1024
        if "/" not in media_type or not valid_count:
            raise RequestError(f"--artifact {index} has invalid media type or byte count")
        result.append(
            {
                "url": url,
                "sha256": digest,
                "media_type": media_type,
                "byte_count": byte_count,
                "label": label,
            }
        )
    if len(result) > 12:
        raise RequestError("at most 12 durable artifacts are supported")
    return result


def build_request(
    *,
    request_id: str | None,
    group_id: str,
    voice: str,
    agent_name: str,
    subject: str,
    summary: str,
    body: str,
    artifacts: list[dict[str, Any]],
    questions: list[dict[str, Any]],
) -> dict[str, Any]:
    values = {
        "group_id": _text(group_id, "TTS29_GROUP_ID", 128),
        "voice": _text(voice, "voice", 64),
        "agent_name": _text(agent_name, "agent name", 80),
        "subject": _text(subject, "subject", 80),
        "summary": _text(summary, "summary", 280),
        "body": _text(body, "message", 40_000),
        "attachments": artifacts,
        "questions": questions,
    }
    if len(values["subject"].split()) > 10:
        raise RequestError("subject must not exceed 10 words")
    word_count = len(values["body"].split())
    if word_count > 330:
        raise RequestError(f"message contains {word_count} words; the enforced limit is 330")
    if request_id is None:
        canonical = json.dumps(values, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        request_id = "skill-" + hashlib.sha256(canonical.encode()).hexdigest()[:32]
    if not REQUEST_ID.fullmatch(request_id):
        raise RequestError("request ID must use 1-64 letters, digits, hyphens, or underscores")
    return {"request_id": request_id, **values}

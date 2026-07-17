#!/usr/bin/env python3
"""Safe MCP views and resource resolution for durable TTS state."""

from __future__ import annotations

import copy
import json
import mimetypes
from pathlib import Path

from tts_remote_state import read_json, tts_state_dir


PRIVATE_KEYS = {
    "answer_attachment_paths",
    "asset_directory",
    "audio_file",
    "iterm_session_id",
    "output_file",
    "path",
    "retry_command",
    "source_file",
    "wait_command",
    "workspace",
}


def sanitize_value(value: object) -> object:
    if isinstance(value, list):
        return [sanitize_value(item) for item in value]
    if not isinstance(value, dict):
        return value
    return {
        str(key): sanitize_value(item)
        for key, item in value.items()
        if key not in PRIVATE_KEYS
    }


def sanitize_item(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        return {}
    item = sanitize_value(copy.deepcopy(value))
    item_id = str(value.get("id") or "")
    if item_id:
        item["uri"] = f"tts://items/{item_id}"
        if value.get("output_file"):
            item["audio_uri"] = f"tts://items/{item_id}/audio"
        attachments = item.get("attachments")
        if isinstance(attachments, list):
            for index, attachment in enumerate(attachments):
                if isinstance(attachment, dict):
                    attachment["resource_uri"] = f"tts://items/{item_id}/attachments/{index}"
    return item


def raw_item(item_id: str) -> dict[str, object]:
    if not safe_identifier(item_id):
        raise ValueError("invalid TTS item identifier")
    value = read_json(tts_state_dir() / "items" / f"{item_id}.json", {})
    if not isinstance(value, dict) or value.get("id") != item_id:
        raise FileNotFoundError(f"TTS item not found: {item_id}")
    return value


def item_json(item_id: str) -> str:
    return json.dumps(sanitize_item(raw_item(item_id)), ensure_ascii=False, indent=2, sort_keys=True)


def item_audio(item_id: str) -> bytes:
    item = raw_item(item_id)
    return referenced_file(item.get("output_file")).read_bytes()


def item_attachment(item_id: str, index: str) -> tuple[bytes, str]:
    item = raw_item(item_id)
    try:
        attachment = (item.get("attachments") or [])[int(index)]
    except (IndexError, TypeError, ValueError) as error:
        raise FileNotFoundError("TTS attachment not found") from error
    if not isinstance(attachment, dict):
        raise FileNotFoundError("TTS attachment not found")
    path = referenced_file(
        attachment.get("source_file") or attachment.get("audio_file") or attachment.get("path")
    )
    return path.read_bytes(), mimetypes.guess_type(path.name)[0] or "application/octet-stream"


def referenced_file(value: object) -> Path:
    path = Path(str(value or "")).resolve()
    if not value or not path.is_file():
        raise FileNotFoundError("TTS resource file is unavailable")
    return path


def safe_identifier(value: str) -> bool:
    return bool(value) and len(value) <= 128 and all(character.isalnum() or character in "-_." for character in value)

"""Harness operation extraction and Codex transcript recovery."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from .core import resolve_path
from .git import git_command_cwd


def extract_operation(payload: dict[str, Any]) -> dict[str, Any]:
    event = payload.get("event") if isinstance(payload.get("event"), dict) else {}
    tool = payload.get("tool") if isinstance(payload.get("tool"), dict) else {}
    tool_name = (
        payload.get("tool_name")
        or event.get("tool_name")
        or tool.get("name")
        or payload.get("tool")
        or ""
    )
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = tool.get("input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    command = tool_input.get("command") or tool_input.get("cmd") or payload.get("command") or ""
    return {"tool_name": str(tool_name), "command": str(command), "tool_input": tool_input}


def recover_codex_exec_workdir(payload: dict[str, Any]) -> dict[str, Any]:
    """Restore exec_command.workdir when Codex flattens the hook tool input."""
    operation = extract_operation(payload)
    if operation.get("tool_name") not in {"Bash", "Shell"}:
        return payload

    tool_input = operation.get("tool_input")
    if not isinstance(tool_input, dict) or operation_workdir(tool_input):
        return payload

    command = str(operation.get("command") or "")
    transcript_path = payload_string(payload, "transcript_path", "transcriptPath")
    recovered = codex_exec_command_from_transcript(
        transcript_path=transcript_path,
        command=command,
        turn_id=payload_string(payload, "turn_id", "turnId"),
    )
    if recovered is None:
        return payload

    recovered_workdir = operation_workdir(recovered)
    if not recovered_workdir:
        return payload

    updated = dict(payload)
    updated_tool_input = dict(tool_input)
    updated_tool_input["workdir"] = recovered_workdir
    updated["tool_input"] = updated_tool_input
    return updated


def codex_exec_command_from_transcript(
    *, transcript_path: str, command: str, turn_id: str
) -> dict[str, Any] | None:
    if not transcript_path or not command:
        return None

    path = Path(transcript_path).expanduser()
    try:
        lines = transcript_tail_lines(path)
    except OSError:
        return None

    for line in reversed(lines):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        item = codex_exec_transcript_item(record)
        if item is None:
            continue

        item_turn_id = codex_transcript_turn_id(item)
        if turn_id and item_turn_id != turn_id:
            return None

        nested_input = item.get("input")
        if not isinstance(nested_input, str):
            return None
        exec_input = parse_exec_command_call(nested_input, command=command)
        if exec_input is None:
            return None
        return exec_input
    return None


def transcript_tail_lines(path: Path, max_bytes: int = 1024 * 1024) -> list[str]:
    with path.open("rb") as handle:
        size = handle.seek(0, os.SEEK_END)
        start = max(0, size - max_bytes)
        handle.seek(start)
        data = handle.read()
    if start:
        _, separator, data = data.partition(b"\n")
        if not separator:
            return []
    return data.decode("utf-8", errors="replace").splitlines()


def codex_exec_transcript_item(record: Any) -> dict[str, Any] | None:
    if not isinstance(record, dict) or record.get("type") != "response_item":
        return None
    item = record.get("payload")
    if not isinstance(item, dict):
        return None
    if item.get("type") != "custom_tool_call" or item.get("name") != "exec":
        return None
    return item


def codex_transcript_turn_id(item: dict[str, Any]) -> str:
    metadata = item.get("internal_chat_message_metadata_passthrough")
    if not isinstance(metadata, dict):
        return ""
    value = metadata.get("turn_id")
    return str(value) if value is not None else ""


def parse_exec_command_call(source: str, *, command: str) -> dict[str, Any] | None:
    marker = "tools.exec_command("
    matches: list[dict[str, Any]] = []
    offset = 0
    while True:
        marker_index = source.find(marker, offset)
        if marker_index < 0:
            break
        argument = source[marker_index + len(marker) :].lstrip()
        try:
            value, _ = json.JSONDecoder().raw_decode(argument)
        except json.JSONDecodeError:
            pass
        else:
            if isinstance(value, dict) and str(value.get("cmd") or "") == command:
                matches.append(value)
        offset = marker_index + len(marker)
    return matches[0] if len(matches) == 1 else None


def effective_operation_cwd(operation: dict[str, Any], fallback: Path) -> Path:
    cwd = fallback
    tool_input = operation.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("workdir", "cwd", "working_directory", "directory"):
            raw_value = tool_input.get(key)
            if not isinstance(raw_value, str) or not raw_value.strip():
                continue
            candidate = Path(raw_value).expanduser()
            if not candidate.is_absolute():
                candidate = fallback / candidate
            cwd = resolve_path(candidate)
            break

    command_cwd = git_command_cwd(operation.get("command", ""), cwd)
    return command_cwd or cwd


def operation_workdir(tool_input: dict[str, Any]) -> str:
    for key in ("workdir", "cwd", "working_directory", "directory"):
        value = tool_input.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def payload_string(payload: dict[str, Any], *keys: str) -> str:
    for key in keys:
        value = payload.get(key)
        if value is not None:
            return str(value)
    return ""

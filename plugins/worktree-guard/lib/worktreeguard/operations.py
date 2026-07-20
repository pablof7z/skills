"""Extract harness operations, working directories, and native write targets."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from .core import resolve_path


NATIVE_WRITE_TOOLS = frozenset(
    {"applypatch", "edit", "write", "multiedit", "notebookedit"}
)
PATH_INPUT_KEYS = ("file_path", "filepath", "path", "filename", "notebook_path")
PATCH_PATH_PREFIXES = (
    "*** Add File: ",
    "*** Delete File: ",
    "*** Update File: ",
    "*** Move to: ",
)


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
    raw_input = payload.get("tool_input")
    if not isinstance(raw_input, (dict, str)):
        raw_input = event.get("tool_input")
    if not isinstance(raw_input, (dict, str)):
        raw_input = tool.get("input")
    tool_input = raw_input if isinstance(raw_input, dict) else {}
    command = tool_input.get("command") or tool_input.get("cmd") or payload.get("command") or ""
    return {
        "tool_name": str(tool_name),
        "command": str(command),
        "tool_input": tool_input,
        "raw_input": raw_input if isinstance(raw_input, str) else "",
    }


def operation_cwd(operation: dict[str, Any], fallback: Path) -> Path:
    tool_input = operation.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("workdir", "cwd", "working_directory", "directory"):
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                candidate = Path(value).expanduser()
                return resolve_path(candidate if candidate.is_absolute() else fallback / candidate)
    return resolve_path(fallback)


def operation_is_native_write(operation: dict[str, Any]) -> bool:
    return normalized_tool_name(str(operation.get("tool_name") or "")) in NATIVE_WRITE_TOOLS


def native_write_targets(operation: dict[str, Any], cwd: Path) -> list[Path]:
    """Return ordinary target paths exposed by a harness-native write tool."""
    targets: list[Path] = []
    tool_input = operation.get("tool_input")
    if isinstance(tool_input, dict):
        targets.extend(paths_from_mapping(tool_input, cwd))

    if normalized_tool_name(str(operation.get("tool_name") or "")) == "applypatch":
        patch = patch_body(operation)
        targets.extend(apply_patch_targets(patch, cwd))
    return list(dict.fromkeys(targets))


def paths_from_mapping(tool_input: dict[str, Any], cwd: Path) -> list[Path]:
    targets: list[Path] = []
    for key in PATH_INPUT_KEYS:
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            targets.append(resolve_operation_path(value, cwd))
    edits = tool_input.get("edits")
    if isinstance(edits, list):
        for edit in edits:
            if isinstance(edit, dict):
                targets.extend(paths_from_mapping(edit, cwd))
    return targets


def patch_body(operation: dict[str, Any]) -> str:
    tool_input = operation.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("patch", "input", "command"):
            value = tool_input.get(key)
            if isinstance(value, str):
                return value
    raw_input = operation.get("raw_input")
    if isinstance(raw_input, str) and raw_input:
        return raw_input
    command = operation.get("command")
    return command if isinstance(command, str) else ""


def apply_patch_targets(patch: str, cwd: Path) -> list[Path]:
    targets: list[Path] = []
    for line in patch.splitlines():
        for prefix in PATCH_PATH_PREFIXES:
            if line.startswith(prefix):
                value = line.removeprefix(prefix).strip()
                if value:
                    targets.append(resolve_operation_path(value, cwd))
                break
    return targets


def resolve_operation_path(value: str, cwd: Path) -> Path:
    candidate = Path(os.path.expandvars(value)).expanduser()
    return resolve_path(candidate if candidate.is_absolute() else cwd / candidate)


def normalized_tool_name(tool_name: str) -> str:
    return tool_name.replace("_", "").replace("-", "").lower()


def recover_codex_exec_workdir(payload: dict[str, Any]) -> dict[str, Any]:
    """Recover workdir when the Codex hook bridge flattened exec input."""
    operation = extract_operation(payload)
    tool_input = operation["tool_input"]
    if operation["tool_name"] not in {"Bash", "Shell"} or operation_workdir(tool_input):
        return payload
    recovered = transcript_exec_input(
        transcript_path=payload_string(payload, "transcript_path", "transcriptPath"),
        command=operation["command"],
        turn_id=payload_string(payload, "turn_id", "turnId"),
    )
    workdir = operation_workdir(recovered or {})
    if not workdir:
        return payload
    updated = dict(payload)
    updated["tool_input"] = {**tool_input, "workdir": workdir}
    return updated


def transcript_exec_input(*, transcript_path: str, command: str, turn_id: str) -> dict[str, Any] | None:
    if not transcript_path or not command:
        return None
    try:
        lines = transcript_tail_lines(Path(transcript_path).expanduser())
    except OSError:
        return None
    for line in reversed(lines):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        item = record.get("payload") if isinstance(record, dict) else None
        if not isinstance(item, dict) or record.get("type") != "response_item":
            continue
        if item.get("type") != "custom_tool_call" or item.get("name") != "exec":
            continue
        metadata = item.get("internal_chat_message_metadata_passthrough")
        item_turn = str(metadata.get("turn_id") or "") if isinstance(metadata, dict) else ""
        if turn_id and item_turn != turn_id:
            return None
        source = item.get("input")
        return parse_exec_call(source, command) if isinstance(source, str) else None
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


def parse_exec_call(source: str, command: str) -> dict[str, Any] | None:
    marker = "tools.exec_command("
    matches: list[dict[str, Any]] = []
    offset = 0
    while (index := source.find(marker, offset)) >= 0:
        argument = source[index + len(marker) :].lstrip()
        try:
            value, _ = json.JSONDecoder().raw_decode(argument)
        except json.JSONDecodeError:
            value = None
        if isinstance(value, dict) and str(value.get("cmd") or "") == command:
            matches.append(value)
        offset = index + len(marker)
    return matches[0] if len(matches) == 1 else None


def operation_workdir(tool_input: dict[str, Any]) -> str:
    for key in ("workdir", "cwd", "working_directory", "directory"):
        value = tool_input.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def payload_string(payload: dict[str, Any], *keys: str) -> str:
    for key in keys:
        if payload.get(key) is not None:
            return str(payload[key])
    return ""

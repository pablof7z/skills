#!/usr/bin/env python3
"""Materialize accepted paired requests on the computer that runs TTS."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

from tts_remote_state import read_json, tts_state_dir, write_json


SCRIPT_DIR = Path(__file__).resolve().parent


def materialize_request(
    content: dict[str, object],
    event: dict[str, object],
) -> dict[str, object]:
    item_id = str(event.get("id") or "")
    command = [
        str(SCRIPT_DIR / "tts"),
        "--agent-name", str(content.get("agent_name") or "remote"),
        "--subject", str(content.get("subject") or "Remote TTS request from paired host"),
        "--summary", str(content.get("summary") or content.get("message") or "Remote spoken update"),
        "--message", str(content.get("message") or ""),
    ]
    for attachment in content.get("attachments") or []:
        path = Path(str(attachment.get("path") or "")).resolve()
        label = str(attachment.get("label") or path.name)
        command.extend(["--attach", label, str(path)])
    if content.get("ask"):
        command.extend(["--wait", str(content["wait"]), "--ask", str(content["ask"])])
    no_play = content.get("action") == "generate" or (
        environment_enabled("TTS_REMOTE_DAEMON_NO_PLAY") and not content.get("ask")
    )
    if no_play:
        command.append("--no-play")
    environment = os.environ.copy()
    environment["TTS_ITEM_ID"] = item_id
    environment["TTS_FORCE_LOCAL"] = "1"
    environment["TTS_REMOTE_MATERIALIZATION"] = "1"
    if content.get("session_id"):
        environment["TTS_SESSION_ID"] = str(content["session_id"])
    if content.get("harness"):
        environment["TTS_HARNESS"] = str(content["harness"])
    completed = subprocess.run(
        command,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    output = json.loads(completed.stdout)
    item_path = tts_state_dir() / "items" / f"{item_id}.json"
    item = read_json(item_path, {})
    if isinstance(item, dict):
        item["remote_request"] = {"transport": "kind:9", "event_id": event.get("id")}
        write_json(item_path, item)
    return output


def safe_materialization_detail(stderr: str | None) -> str:
    lines = [
        line.strip()
        for line in (stderr or "").splitlines()
        if line.strip().startswith(("Error:", "Warning:"))
    ]
    return " | ".join(lines[-3:])[:1000] or "local TTS command exited without a diagnostic"


def materialization_guidance(detail: str) -> str:
    if detail == "local TTS command exited without a diagnostic":
        return "The laptop TTS command failed before queueing. Check its daemon log and retry."
    return f"Laptop TTS: {detail}"


def environment_enabled(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}

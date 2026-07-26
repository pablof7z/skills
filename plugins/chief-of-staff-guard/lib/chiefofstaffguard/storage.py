"""Denial-log storage.

ChiefOfStaffGuard has no grant, auto-grant, or override state -- there is
deliberately no self-serve escalation path (see README). The only durable
state it keeps is an append-only log of blocked actions.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from .core import DEFAULT_DENY_LOG_FILE, resolve_path


def load_hook_payload(stdin: bytes) -> dict[str, Any]:
    try:
        payload = json.loads(stdin.decode("utf-8")) if stdin.strip() else {}
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def deny_log_path() -> Path:
    override = os.environ.get("COSG_DENY_LOG_FILE")
    return resolve_path(override) if override else Path.home() / DEFAULT_DENY_LOG_FILE


def stable_hook_shim_path(harness: str) -> Path:
    return Path.home() / ".local/bin" / f"cosg-hook-{harness}"


def write_denial(record: dict[str, Any]) -> None:
    path = deny_log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        pass


def read_denials() -> list[dict[str, Any]]:
    try:
        lines = deny_log_path().read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    records: list[dict[str, Any]] = []
    for line in lines:
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)
    return records

"""Small JSON state store used by endpoint runtimes."""

from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path
from typing import Any


DEFAULT_STATE = {
    "version": 1,
    "approved_backends": {},
    "consumed_pairings": [],
    "seen_events": [],
    "replied_requests": {},
}


class JsonState:
    def __init__(self, path: Path):
        self.path = path

    def load(self) -> dict[str, Any]:
        if not self.path.is_file():
            return deepcopy(DEFAULT_STATE)
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return deepcopy(DEFAULT_STATE)
        if not isinstance(payload, dict):
            return deepcopy(DEFAULT_STATE)
        for key, value in DEFAULT_STATE.items():
            payload.setdefault(key, deepcopy(value))
        return payload

    def save(self, payload: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

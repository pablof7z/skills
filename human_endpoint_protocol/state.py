"""Small JSON state store used by endpoint runtimes."""

from __future__ import annotations

import json
import os
import tempfile
from copy import deepcopy
from pathlib import Path
from typing import Any


DEFAULT_STATE = {
    "version": 1,
    "approved_backends": {},
    "consumed_pairings": [],
    "seen_events": [],
    "seen_replies": [],
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
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.path.parent, 0o700)
        data = json.dumps(payload, indent=2, sort_keys=True) + "\n"
        fd, temporary = tempfile.mkstemp(prefix=f".{self.path.name}.", dir=self.path.parent, text=True)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.path)
            os.chmod(self.path, 0o600)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise

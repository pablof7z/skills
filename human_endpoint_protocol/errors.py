"""Structured errors for remote human endpoint operations."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any


@dataclass
class RemoteHumanError(Exception):
    code: str
    message: str
    details: dict[str, Any] = field(default_factory=dict)

    def __str__(self) -> str:
        return f"{self.code}: {self.message}"

    def to_json(self) -> str:
        return json.dumps(
            {
                "ok": False,
                "code": self.code,
                "message": self.message,
                "details": self.details,
            },
            sort_keys=True,
        )

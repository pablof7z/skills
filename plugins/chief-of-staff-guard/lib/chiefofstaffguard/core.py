"""Small shared types and helpers for ChiefOfStaffGuard."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


CHIEF_OF_STAFF_SLUG = "chief-of-staff"
DEFAULT_DENY_LOG_FILE = "chief-of-staff-guard-denied-actions.jsonl"


class ChiefOfStaffGuardError(RuntimeError):
    pass


def resolve_path(raw_path: str | Path) -> Path:
    return Path(raw_path).expanduser().resolve(strict=False)


def emit(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")

#!/usr/bin/env python3
"""Short-lived local approval codes for TTS MCP OAuth."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hmac
import os
from pathlib import Path
import secrets
import time
from typing import Callable, Iterator

from tts_remote_state import read_json, tts_state_dir, write_json


PAIRING_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
PAIRING_CODE_LENGTH = 4
PAIRING_TTL_SECONDS = 300
MAX_FAILED_ATTEMPTS = 10


@dataclass(frozen=True)
class PairingCode:
    code: str
    created_at: int
    expires_at: int
    failed_attempts: int = 0

    def public_dict(self) -> dict[str, object]:
        return {
            "code": self.code,
            "created_at": self.created_at,
            "expires_at": self.expires_at,
            "ttl_seconds": PAIRING_TTL_SECONDS,
        }


class PairingCodeStore:
    def __init__(
        self,
        path: Path | None = None,
        *,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.path = path or (tts_state_dir() / "mcp" / "oauth-pairing.json")
        self.lock_path = self.path.with_suffix(".lock")
        self.clock = clock

    def current(self) -> PairingCode:
        with self._locked():
            value = self._read()
            if value is None or value.expires_at <= int(self.clock()):
                return self._rotate_locked()
            return value

    def rotate(self) -> PairingCode:
        with self._locked():
            return self._rotate_locked()

    def verify_and_consume(self, submitted: str) -> tuple[bool, str]:
        normalized = "".join(submitted.upper().split())
        with self._locked():
            value = self._read()
            now = int(self.clock())
            if value is None or value.expires_at <= now:
                self._rotate_locked()
                return False, "expired"
            if hmac.compare_digest(value.code, normalized):
                write_json(
                    self.path,
                    {"consumed_at": now, "expires_at": value.expires_at},
                )
                return True, "approved"
            attempts = value.failed_attempts + 1
            if attempts >= MAX_FAILED_ATTEMPTS:
                self._rotate_locked()
                return False, "rate_limited"
            write_json(
                self.path,
                {
                    "code": value.code,
                    "created_at": value.created_at,
                    "expires_at": value.expires_at,
                    "failed_attempts": attempts,
                },
            )
            return False, "invalid"

    def _read(self) -> PairingCode | None:
        value = read_json(self.path, {})
        if not isinstance(value, dict) or not isinstance(value.get("code"), str):
            return None
        try:
            return PairingCode(
                code=str(value["code"]),
                created_at=int(value["created_at"]),
                expires_at=int(value["expires_at"]),
                failed_attempts=int(value.get("failed_attempts") or 0),
            )
        except (KeyError, TypeError, ValueError):
            return None

    def _rotate_locked(self) -> PairingCode:
        now = int(self.clock())
        value = PairingCode(
            code="".join(
                secrets.choice(PAIRING_ALPHABET) for _ in range(PAIRING_CODE_LENGTH)
            ),
            created_at=now,
            expires_at=now + PAIRING_TTL_SECONDS,
        )
        write_json(self.path, {**value.public_dict(), "failed_attempts": 0})
        return value

    @contextmanager
    def _locked(self) -> Iterator[None]:
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        self.lock_path.parent.chmod(0o700)
        with self.lock_path.open("a+", encoding="utf-8") as handle:
            os.chmod(self.lock_path, 0o600)
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

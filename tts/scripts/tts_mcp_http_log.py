#!/usr/bin/env python3
"""Privacy-safe inbound HTTP header monitoring for TTS MCP."""

from __future__ import annotations

from contextvars import ContextVar
import hashlib
import json
import os
from pathlib import Path
import time
from urllib.parse import parse_qsl

from tts_remote_state import tts_state_dir


SENSITIVE_NAMES = {
    "authorization",
    "cookie",
    "proxy-authorization",
    "x-api-key",
    "x-auth-token",
    "x-forwarded-client-cert",
}
MAX_LOG_BYTES = 2 * 1024 * 1024
MAX_HEADER_VALUE = 512
_REQUEST_HEADERS: ContextVar[dict[str, str] | None] = ContextVar(
    "tts_mcp_request_headers", default=None
)


class HeaderTrafficStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or (tts_state_dir() / "mcp" / "http-headers.jsonl")

    def append(self, entry: dict[str, object]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.parent.chmod(0o700)
        if self.path.is_file() and self.path.stat().st_size >= MAX_LOG_BYTES:
            self.path.replace(self.path.with_suffix(".previous.jsonl"))
        descriptor = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(
                descriptor,
                (json.dumps(entry, ensure_ascii=False, sort_keys=True) + "\n").encode(
                    "utf-8"
                ),
            )
        finally:
            os.close(descriptor)
        self.path.chmod(0o600)

    def recent(self, limit: int = 50) -> dict[str, object]:
        if not 1 <= limit <= 200:
            raise ValueError("limit must be between 1 and 200")
        try:
            lines = self.path.read_text(encoding="utf-8").splitlines()
        except (FileNotFoundError, OSError):
            lines = []
        entries: list[dict[str, object]] = []
        for line in reversed(lines[-limit:]):
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict):
                entries.append(value)
        return {"count": len(entries), "entries": entries}


class HeaderAuditMiddleware:
    def __init__(self, app, store: HeaderTrafficStore | None = None) -> None:
        self.app = app
        self.store = store or HeaderTrafficStore()

    async def __call__(self, scope, receive, send) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return
        started = time.time()
        status = 500
        request_headers = decoded_headers(scope.get("headers", []))
        context_token = _REQUEST_HEADERS.set(request_headers)

        async def capture(message) -> None:
            nonlocal status
            if message.get("type") == "http.response.start":
                status = int(message.get("status") or 500)
            await send(message)

        try:
            await self.app(scope, receive, capture)
        finally:
            try:
                self.store.append(
                    {
                        "timestamp": int(started),
                        "duration_ms": round((time.time() - started) * 1000, 2),
                        "method": scope.get("method"),
                        "path": scope.get("path"),
                        "query_keys": sorted(
                            {
                                key
                                for key, _value in parse_qsl(
                                    scope.get("query_string", b"").decode("utf-8", "ignore")
                                )
                            }
                        ),
                        "client": client_value(scope.get("client")),
                        "status": status,
                        "headers": sanitized_headers(scope.get("headers", [])),
                    }
                )
            finally:
                _REQUEST_HEADERS.reset(context_token)


def current_request_header(name: str) -> str | None:
    headers = _REQUEST_HEADERS.get()
    value = headers.get(name.lower()) if headers else None
    return value if value and len(value) <= MAX_HEADER_VALUE else None


def in_http_request() -> bool:
    return _REQUEST_HEADERS.get() is not None


def decoded_headers(rows: list[tuple[bytes, bytes]]) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw_name, raw_value in rows:
        name = raw_name.decode("latin-1").lower()
        value = raw_value.decode("latin-1", errors="replace")
        result[name] = f"{result[name]}, {value}" if name in result else value
    return result


def sanitized_headers(rows: list[tuple[bytes, bytes]]) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw_name, raw_value in rows:
        name = raw_name.decode("latin-1").lower()
        value = raw_value.decode("latin-1", errors="replace")
        if is_sensitive(name):
            value = redacted_value(name, value)
        elif len(value) > MAX_HEADER_VALUE:
            value = value[:MAX_HEADER_VALUE] + "<truncated>"
        result[name] = f"{result[name]}, {value}" if name in result else value
    return result


def is_sensitive(name: str) -> bool:
    return name in SENSITIVE_NAMES or any(
        part in name for part in ("token", "secret", "cookie", "key")
    )


def redacted_value(name: str, value: str) -> str:
    fingerprint = hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]
    scheme = (
        value.split(" ", 1)[0]
        if name in {"authorization", "proxy-authorization"}
        else "value"
    )
    return f"{scheme} <redacted:{fingerprint}>"


def client_value(value: object) -> str | None:
    if isinstance(value, (list, tuple)) and len(value) == 2:
        return f"{value[0]}:{value[1]}"
    return None

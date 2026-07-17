#!/usr/bin/env python3
"""Upload generated TTS audio to a Blossom server."""

from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from tts_remote_event import NOSTR_EVENT_FIELDS
from tts_remote_signing import signed_event


DEFAULT_SERVER = "https://blossom.primal.net"
DEFAULT_MAX_BYTES = 50 * 1024 * 1024


class BlossomUploadError(RuntimeError):
    """A Blossom upload failed or returned an invalid descriptor."""


def upload_mp3(path: Path, *, nsec: str, server: str | None = None) -> dict[str, object]:
    source = path.resolve()
    if not source.is_file():
        raise BlossomUploadError("generated MP3 is missing")
    payload = source.read_bytes()
    if not payload:
        raise BlossomUploadError("generated MP3 is empty")
    if len(payload) > max_upload_bytes():
        raise BlossomUploadError("generated MP3 exceeds the Blossom upload limit")
    target = normalized_server(server or os.environ.get("TTS_BLOSSOM_SERVER") or DEFAULT_SERVER)
    sha256 = hashlib.sha256(payload).hexdigest()
    request = Request(
        f"{target}/upload",
        data=payload,
        method="PUT",
        headers={
            "Authorization": authorization_header(target, sha256, nsec),
            "Content-Type": "audio/mpeg",
            "Content-Length": str(len(payload)),
            "X-SHA-256": sha256,
        },
    )
    try:
        with urlopen(request, timeout=upload_timeout()) as response:
            descriptor = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        reason = error.headers.get("X-Reason") or error.reason or f"HTTP {error.code}"
        raise BlossomUploadError(f"Blossom upload rejected: {reason}") from error
    except (OSError, URLError, ValueError) as error:
        raise BlossomUploadError(f"Blossom upload failed: {error}") from error
    return validated_descriptor(descriptor, sha256=sha256, size=len(payload), server=target)


def authorization_header(server: str, sha256: str, nsec: str) -> str:
    hostname = urlparse(server).hostname or ""
    event = signed_event(
        kind=24242,
        content="Upload generated TTS audio",
        tags=[
            ["t", "upload"],
            ["expiration", str(int(time.time()) + auth_lifetime())],
            ["server", hostname.lower()],
            ["x", sha256],
        ],
        nsec=nsec,
    )
    wire = {key: value for key, value in event.items() if key in NOSTR_EVENT_FIELDS}
    encoded = base64.urlsafe_b64encode(
        json.dumps(wire, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ).decode("ascii").rstrip("=")
    return f"Nostr {encoded}"


def validated_descriptor(
    value: object,
    *,
    sha256: str,
    size: int,
    server: str,
) -> dict[str, object]:
    if not isinstance(value, dict):
        raise BlossomUploadError("Blossom returned a non-object descriptor")
    url = value.get("url")
    parsed = urlparse(str(url or ""))
    if parsed.scheme != "https" or not parsed.hostname:
        raise BlossomUploadError("Blossom returned an invalid public URL")
    if str(value.get("sha256") or "").lower() != sha256:
        raise BlossomUploadError("Blossom descriptor hash does not match the MP3")
    try:
        descriptor_size = int(value.get("size"))
    except (TypeError, ValueError) as error:
        raise BlossomUploadError("Blossom descriptor has an invalid size") from error
    if descriptor_size != size:
        raise BlossomUploadError("Blossom descriptor size does not match the MP3")
    mime_type = str(value.get("type") or "")
    if mime_type not in {"audio/mpeg", "audio/mp3", "application/octet-stream"}:
        raise BlossomUploadError("Blossom descriptor is not an MP3")
    uploaded = value.get("uploaded")
    if not isinstance(uploaded, int):
        try:
            uploaded = int(uploaded)
        except (TypeError, ValueError) as error:
            raise BlossomUploadError("Blossom descriptor has an invalid upload time") from error
    return {
        "status": "uploaded",
        "url": str(url),
        "sha256": sha256,
        "size": size,
        "type": "audio/mpeg",
        "uploaded": uploaded,
        "server": server,
    }


def normalized_server(value: str) -> str:
    parsed = urlparse(value.rstrip("/"))
    local_http = parsed.scheme == "http" and loopback_host(parsed.hostname)
    if (parsed.scheme != "https" and not local_http) or not parsed.hostname or parsed.path not in {"", "/"}:
        raise BlossomUploadError("Blossom server must be an HTTPS origin")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise BlossomUploadError("Blossom server must not include credentials, query, or fragment")
    return value.rstrip("/")


def loopback_host(value: str | None) -> bool:
    if value == "localhost":
        return True
    try:
        return bool(value and ipaddress.ip_address(value).is_loopback)
    except ValueError:
        return False


def environment_number(name: str, default: float, minimum: float, maximum: float) -> float:
    try:
        return max(minimum, min(maximum, float(os.environ.get(name, str(default)))))
    except ValueError:
        return default


def upload_timeout() -> float:
    return environment_number("TTS_BLOSSOM_TIMEOUT_SECONDS", 60.0, 1.0, 300.0)


def auth_lifetime() -> int:
    return int(environment_number("TTS_BLOSSOM_AUTH_SECONDS", 300.0, 30.0, 900.0))


def max_upload_bytes() -> int:
    return int(environment_number("TTS_BLOSSOM_MAX_BYTES", DEFAULT_MAX_BYTES, 1.0, 500 * 1024 * 1024))

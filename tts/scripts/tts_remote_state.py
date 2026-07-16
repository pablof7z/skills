#!/usr/bin/env python3
"""Durable state helpers for remote TTS."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time


def tts_state_dir() -> Path:
    if os.environ.get("TTS_STATE_DIR"):
        return Path(os.environ["TTS_STATE_DIR"])
    if os.environ.get("XDG_STATE_HOME"):
        return Path(os.environ["XDG_STATE_HOME"]) / "tts"
    if os.environ.get("HOME"):
        return Path(os.environ["HOME"]) / ".local" / "state" / "tts"
    return Path("/tmp/tts-state")


def remote_dir() -> Path:
    path = tts_state_dir() / "remote"
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


def read_json(path: Path, default: object) -> object:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, OSError, ValueError):
        return default


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.stem}.", suffix=".tmp", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def pubkey_for_nsec(nsec: str) -> str:
    return hashlib.sha256(nsec.encode("utf-8")).hexdigest()


def generated_secret() -> str:
    if os.environ.get("TTS_REMOTE_TRANSPORT") == "file" or os.environ.get("TTS_FAKE_NOSTR") == "1":
        return "nsec" + secrets.token_urlsafe(32)
    process = subprocess.run(
        [os.environ.get("TTS_NAK_BIN", "nak"), "key", "generate"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise RuntimeError(process.stderr.strip() or "nak key generate failed")
    return process.stdout.strip()


def public_key_for_secret(nsec: str) -> str:
    if os.environ.get("TTS_REMOTE_TRANSPORT") == "file" or os.environ.get("TTS_FAKE_NOSTR") == "1":
        return pubkey_for_nsec(nsec)
    process = subprocess.run(
        [os.environ.get("TTS_NAK_BIN", "nak"), "key", "public"],
        env={**os.environ, "NOSTR_SECRET_KEY": nsec},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise RuntimeError(process.stderr.strip() or "nak key public failed")
    return process.stdout.strip()


def ensure_backend() -> dict[str, object]:
    path = remote_dir() / "backend.json"
    existing = read_json(path, {})
    if isinstance(existing, dict) and existing.get("nsec") and existing.get("pubkey"):
        return existing
    nsec = generated_secret()
    backend = {
        "nsec": nsec,
        "pubkey": public_key_for_secret(nsec),
        "product": "tts",
        "approved": True,
        "hostname": socket.gethostname(),
        "created_at": int(time.time()),
    }
    write_json(path, backend)
    return backend


def ensure_laptop_identity(pubkey: str | None = None) -> dict[str, object]:
    path = remote_dir() / "laptop.json"
    existing = read_json(path, {})
    if isinstance(existing, dict) and existing.get("pubkey"):
        return existing
    nsec = generated_secret() if not pubkey else None
    identity = {
        "nsec": nsec,
        "pubkey": pubkey or pubkey_for_nsec(str(nsec)),
        "product": "tts",
        "created_at": int(time.time()),
    }
    write_json(path, identity)
    return identity


def peers() -> list[dict[str, object]]:
    loaded = read_json(remote_dir() / "peers.json", [])
    return loaded if isinstance(loaded, list) else []


def save_peers(values: list[dict[str, object]]) -> None:
    write_json(remote_dir() / "peers.json", values)


def upsert_peer(peer: dict[str, object]) -> dict[str, object]:
    values = [value for value in peers() if value.get("id") != peer.get("id")]
    values.append(peer)
    save_peers(values)
    return peer


def active_peer(peer_id: str | None = None) -> dict[str, object] | None:
    candidates = [peer for peer in peers() if peer.get("approved") and not peer.get("revoked_at")]
    if peer_id:
        for peer in candidates:
            if peer.get("id") == peer_id or peer.get("pubkey") == peer_id:
                return peer
        return None
    return candidates[0] if candidates else None


def error(code: str, message: str, guidance: str | None = None) -> dict[str, object]:
    value: dict[str, object] = {"code": code, "message": message}
    if guidance:
        value["guidance"] = guidance
    return {"status": "error", "error": value}

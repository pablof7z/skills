#!/usr/bin/env python3
"""Remote TTS transport adapters."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from tts_remote_state import pubkey_for_nsec


def _event_id(event: dict[str, object], secret: str) -> str:
    payload = json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256((payload + secret).encode("utf-8")).hexdigest()


def signed_event(
    *,
    kind: int,
    content: str,
    tags: list[list[str]],
    nsec: str,
    relay: str | None = None,
) -> dict[str, object]:
    event: dict[str, object] = {
        "kind": kind,
        "pubkey": pubkey_for_nsec(nsec),
        "created_at": int(time.time()),
        "tags": tags,
        "content": content,
    }
    event["id"] = _event_id(event, nsec)
    event["sig"] = hashlib.sha256((str(event["id"]) + nsec).encode("utf-8")).hexdigest()
    if relay:
        event["relay"] = relay
    return event


class Transport:
    def publish(self, event: dict[str, object]) -> dict[str, object]:
        raise NotImplementedError

    def events(self) -> list[dict[str, object]]:
        raise NotImplementedError


class FileTransport(Transport):
    def __init__(self) -> None:
        raw_path = os.environ.get("TTS_REMOTE_TRANSPORT_FILE")
        if not raw_path:
            raw_path = str(Path.home() / ".local" / "state" / "tts" / "remote" / "transport.jsonl")
        self.path = Path(raw_path)

    def publish(self, event: dict[str, object]) -> dict[str, object]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")
        return {"transport": "file", "path": str(self.path)}

    def events(self) -> list[dict[str, object]]:
        if not self.path.is_file():
            return []
        result = []
        for line in self.path.read_text(encoding="utf-8").splitlines():
            try:
                loaded = json.loads(line)
            except ValueError:
                continue
            if isinstance(loaded, dict):
                result.append(loaded)
        return result


class NakTransport(Transport):
    def __init__(self, relay: str | None = None) -> None:
        self.relay = relay

    def publish(self, event: dict[str, object]) -> dict[str, object]:
        relay = self.relay or str(event.get("relay") or "")
        if not relay:
            raise RuntimeError("nak transport requires a relay")
        process = subprocess.run(
            ["nak", "event", relay],
            input=json.dumps(event),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if process.returncode != 0:
            raise RuntimeError(process.stderr.strip() or "nak publish failed")
        return {"transport": "nak", "relay": relay, "stdout": process.stdout.strip()}

    def events(self) -> list[dict[str, object]]:
        raise RuntimeError("daemon event polling is not implemented for nak; use file transport for tests")


def transport(relay: str | None = None) -> Transport:
    selected = os.environ.get("TTS_REMOTE_TRANSPORT", "nak" if relay else "file")
    if selected == "file":
        return FileTransport()
    if selected == "nak":
        return NakTransport(relay)
    raise RuntimeError(f"unsupported TTS remote transport: {selected}")

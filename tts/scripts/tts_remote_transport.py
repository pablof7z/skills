#!/usr/bin/env python3
"""Remote TTS transport adapters."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess


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
            [nak_bin(), "event", relay],
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
        if not self.relay:
            raise RuntimeError("nak transport requires a relay")
        process = subprocess.run(
            [nak_bin(), "req", self.relay],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=float(os.environ.get("TTS_NAK_TIMEOUT_SECONDS", "5")),
        )
        if process.returncode != 0:
            raise RuntimeError(process.stderr.strip() or "nak fetch failed")
        events = []
        for line in process.stdout.splitlines():
            try:
                loaded = json.loads(line)
            except ValueError:
                continue
            if isinstance(loaded, dict):
                events.append(loaded)
        return events


def transport(relay: str | None = None) -> Transport:
    selected = os.environ.get("TTS_REMOTE_TRANSPORT", "nak" if relay else "file")
    if selected == "file":
        return FileTransport()
    if selected == "nak":
        return NakTransport(relay)
    raise RuntimeError(f"unsupported TTS remote transport: {selected}")


def nak_bin() -> str:
    return os.environ.get("TTS_NAK_BIN", "nak")

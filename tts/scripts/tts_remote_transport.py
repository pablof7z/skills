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

    def events(
        self,
        *,
        target_pubkey: str | None = None,
        group_ids: list[str] | None = None,
        since: int | None = None,
    ) -> list[dict[str, object]]:
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

    def events(
        self,
        *,
        target_pubkey: str | None = None,
        group_ids: list[str] | None = None,
        since: int | None = None,
    ) -> list[dict[str, object]]:
        if not self.path.is_file():
            return []
        result = []
        for line in self.path.read_text(encoding="utf-8").splitlines():
            try:
                loaded = json.loads(line)
            except ValueError:
                continue
            if isinstance(loaded, dict) and matches(loaded, target_pubkey, group_ids, since):
                result.append(loaded)
        return result


class NakTransport(Transport):
    def __init__(self, relay: str | None = None) -> None:
        self.relay = relay

    def publish(self, event: dict[str, object]) -> dict[str, object]:
        relay = self.relay or str(event.get("relay") or "")
        if not relay:
            raise RuntimeError("nak transport requires a relay")
        try:
            process = subprocess.run(
                [nak_bin(), "event", relay],
                input=json.dumps(event),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=command_timeout(),
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("nak publish timed out") from error
        if process.returncode != 0:
            raise RuntimeError("nak publish failed")
        return {"transport": "nak", "relay": relay, "stdout": process.stdout.strip()}

    def events(
        self,
        *,
        target_pubkey: str | None = None,
        group_ids: list[str] | None = None,
        since: int | None = None,
    ) -> list[dict[str, object]]:
        if not self.relay:
            raise RuntimeError("nak transport requires a relay")
        command = [nak_bin(), "req", "--paginate", "--limit", str(limit()), "-k", "9", "-k", "24", self.relay]
        command.pop()
        if target_pubkey:
            command.extend(["-p", target_pubkey])
        for group_id in sorted(set(group_ids or [])):
            command.extend(["-h", group_id])
        if since is not None:
            command.extend(["--since", str(max(0, since))])
        command.append(self.relay)
        try:
            process = subprocess.run(
                command,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=float(os.environ.get("TTS_NAK_TIMEOUT_SECONDS", "5")),
            )
        except subprocess.TimeoutExpired as error:
            return with_source_relay(parse_events(normalize_timeout_output(error.stdout)), self.relay)
        if process.returncode != 0:
            raise RuntimeError(process.stderr.strip() or "nak fetch failed")
        return with_source_relay(parse_events(process.stdout), self.relay)


def transport(relay: str | None = None) -> Transport:
    selected = os.environ.get("TTS_REMOTE_TRANSPORT", "nak" if relay else "file")
    if selected == "file":
        return FileTransport()
    if selected == "nak":
        return NakTransport(relay)
    raise RuntimeError(f"unsupported TTS remote transport: {selected}")


def nak_bin() -> str:
    return os.environ.get("TTS_NAK_BIN", "nak")


def limit() -> int:
    try:
        return max(1, min(500, int(os.environ.get("TTS_NAK_REQ_LIMIT", "200"))))
    except ValueError:
        return 200


def command_timeout() -> float:
    try:
        return max(0.1, float(os.environ.get("TTS_NAK_TIMEOUT_SECONDS", "5")))
    except ValueError:
        return 5.0


def normalize_timeout_output(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def parse_events(raw: str) -> list[dict[str, object]]:
    stripped = raw.strip()
    if not stripped:
        return []
    try:
        loaded = json.loads(stripped)
    except ValueError:
        loaded = None
    candidates = loaded if isinstance(loaded, list) else [loaded] if isinstance(loaded, dict) else []
    if not candidates:
        for line in stripped.splitlines():
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if isinstance(item, dict):
                candidates.append(item)
    return [item for item in candidates if isinstance(item, dict)]


def tag_values(event: dict[str, object], name: str) -> set[str]:
    tags = event.get("tags")
    if not isinstance(tags, list):
        return set()
    return {
        str(tag[1])
        for tag in tags
        if isinstance(tag, list) and len(tag) >= 2 and tag[0] == name
    }


def matches(
    event: dict[str, object],
    target_pubkey: str | None,
    group_ids: list[str] | None,
    since: int | None,
) -> bool:
    if target_pubkey and target_pubkey not in tag_values(event, "p"):
        return False
    if group_ids and not tag_values(event, "h").intersection(group_ids):
        return False
    return since is None or int(event.get("created_at") or 0) >= since


def with_source_relay(events: list[dict[str, object]], relay: str) -> list[dict[str, object]]:
    for event in events:
        event["relay"] = relay
    return events

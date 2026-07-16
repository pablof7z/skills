#!/usr/bin/env python3
"""Remote TTS transport adapters."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

from tts_remote_event import (
    NOSTR_EVENT_FIELDS,
    matches,
    parse_events,
    role_tag_values,
    tag_values,
    with_source_relay,
)


class Transport:
    def publish(self, event: dict[str, object]) -> dict[str, object]:
        raise NotImplementedError

    def events(
        self,
        *,
        target_pubkey: str | None = None,
        author_pubkeys: list[str] | None = None,
        group_ids: list[str] | None = None,
        since: int | None = None,
        kinds: list[int] | None = None,
        referenced_event_id: str | None = None,
    ) -> list[dict[str, object]]:
        raise NotImplementedError

    def group_members(self, channel: str) -> set[str]:
        raise NotImplementedError

    def group_admins(self, channel: str) -> set[str]:
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
        author_pubkeys: list[str] | None = None,
        group_ids: list[str] | None = None,
        since: int | None = None,
        kinds: list[int] | None = None,
        referenced_event_id: str | None = None,
    ) -> list[dict[str, object]]:
        if not self.path.is_file():
            return []
        result = []
        for line in self.path.read_text(encoding="utf-8").splitlines():
            try:
                loaded = json.loads(line)
            except ValueError:
                continue
            if isinstance(loaded, dict) and matches(
                loaded,
                target_pubkey,
                author_pubkeys,
                group_ids,
                since,
                kinds,
                referenced_event_id,
            ):
                result.append(loaded)
        return result

    def group_members(self, channel: str) -> set[str]:
        members: set[str] = set()
        for event in self.events():
            kind = int(event.get("kind") or -1)
            if kind == 9000 and channel in tag_values(event, "h"):
                members.update(tag_values(event, "p"))
            if kind in {39001, 39002} and channel in tag_values(event, "d"):
                members.update(tag_values(event, "p"))
        return members

    def group_admins(self, channel: str) -> set[str]:
        admins: set[str] = set()
        for event in self.events():
            kind = int(event.get("kind") or -1)
            if kind == 9007 and channel in tag_values(event, "h"):
                admins.add(str(event.get("pubkey") or ""))
            if kind == 9000 and channel in tag_values(event, "h"):
                admins.update(role_tag_values(event, "p", "admin"))
            if kind == 39001 and channel in tag_values(event, "d"):
                admins.update(tag_values(event, "p"))
        return admins


class NakTransport(Transport):
    def __init__(self, relay: str | None = None) -> None:
        self.relay = relay

    def publish(self, event: dict[str, object]) -> dict[str, object]:
        relay = self.relay or str(event.get("relay") or "")
        if not relay:
            raise RuntimeError("nak transport requires a relay")
        wire_event = {key: value for key, value in event.items() if key in NOSTR_EVENT_FIELDS}
        try:
            process = subprocess.run(
                [nak_bin(), "event", relay],
                input=json.dumps(wire_event),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=command_timeout(),
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("nak publish timed out") from error
        if process.returncode != 0 or "failed:" in process.stderr.lower():
            raise RuntimeError(process.stderr.strip() or "nak publish failed")
        return {"transport": "nak", "relay": relay, "stdout": process.stdout.strip()}

    def events(
        self,
        *,
        target_pubkey: str | None = None,
        author_pubkeys: list[str] | None = None,
        group_ids: list[str] | None = None,
        since: int | None = None,
        kinds: list[int] | None = None,
        referenced_event_id: str | None = None,
    ) -> list[dict[str, object]]:
        if not self.relay:
            raise RuntimeError("nak transport requires a relay")
        requested_kinds = sorted(set(kinds or [9, 24133]))
        live = bool(requested_kinds) and all(20000 <= kind < 30000 for kind in requested_kinds)
        command = [nak_bin(), "req", "--stream" if live else "--paginate", "--limit", str(limit())]
        for kind in requested_kinds:
            command.extend(["-k", str(kind)])
        if target_pubkey:
            command.extend(["-p", target_pubkey])
        for author in sorted(set(author_pubkeys or [])):
            command.extend(["-a", author])
        for group_id in sorted(set(group_ids or [])):
            command.extend(["-h", group_id])
        if referenced_event_id:
            command.extend(["-e", referenced_event_id])
        if since is not None and not live:
            command.extend(["--since", str(max(0, since))])
        command.append(self.relay)
        try:
            process = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=pairing_listen_timeout() if live else command_timeout(),
            )
        except subprocess.TimeoutExpired as error:
            events = with_source_relay(parse_events(normalize_timeout_output(error.stdout)), self.relay)
            return [
                event
                for event in events
                if matches(
                    event,
                    target_pubkey,
                    author_pubkeys,
                    group_ids,
                    since,
                    kinds,
                    referenced_event_id,
                )
            ]
        if process.returncode != 0:
            raise RuntimeError(process.stderr.strip() or "nak fetch failed")
        events = with_source_relay(parse_events(process.stdout), self.relay)
        return [
            event
            for event in events
            if matches(
                event,
                target_pubkey,
                author_pubkeys,
                group_ids,
                since,
                kinds,
                referenced_event_id,
            )
        ]

    def group_members(self, channel: str) -> set[str]:
        return self._group_state(channel, [39001, 39002])

    def group_admins(self, channel: str) -> set[str]:
        return self._group_state(channel, [39001])

    def _group_state(self, channel: str, kinds: list[int]) -> set[str]:
        if not self.relay:
            raise RuntimeError("nak transport requires a relay")
        command = [nak_bin(), "req", "--limit", "2"]
        for kind in kinds:
            command.extend(["-k", str(kind)])
        command.extend(["-d", channel, self.relay])
        try:
            process = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=command_timeout(),
            )
        except subprocess.TimeoutExpired as error:
            events = parse_events(normalize_timeout_output(error.stdout))
        else:
            if process.returncode != 0:
                raise RuntimeError(process.stderr.strip() or "nak group-state fetch failed")
            events = parse_events(process.stdout)
        members: set[str] = set()
        for event in events:
            if channel in tag_values(event, "d"):
                members.update(tag_values(event, "p"))
            if int(event.get("kind") or -1) == 9000 and channel in tag_values(event, "h"):
                if kinds == [39001]:
                    members.update(role_tag_values(event, "p", "admin"))
                else:
                    members.update(tag_values(event, "p"))
        return members


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


def pairing_listen_timeout() -> float:
    try:
        return max(0.25, float(os.environ.get("TTS_PAIRING_LISTEN_SECONDS", "1")))
    except ValueError:
        return 1.0


def normalize_timeout_output(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value

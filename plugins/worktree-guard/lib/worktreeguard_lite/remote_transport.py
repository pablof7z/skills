"""Relay transport adapters for remote WorktreeGuard approval."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

from .core import WorktreeGuardError, resolve_path
from .remote_events import structurally_valid_event, verified_fake_event


class Transport:
    def publish(self, relay: str, event: dict[str, Any]) -> dict[str, Any]:
        raise NotImplementedError

    def fetch(
        self,
        relay: str,
        *,
        kinds: set[int] | None = None,
        p_tag: str = "",
        h_tag: str = "",
    ) -> list[dict[str, Any]]:
        raise NotImplementedError


class FakeTransport(Transport):
    def __init__(self, path: Path) -> None:
        self.path = path

    def publish(self, relay: str, event: dict[str, Any]) -> dict[str, Any]:
        if not verified_fake_event(event):
            raise WorktreeGuardError("fake transport refused an unverifiable event.")
        record = dict(event)
        record.pop("_secret", None)
        record["relay"] = relay
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        return record

    def fetch(
        self,
        relay: str,
        *,
        kinds: set[int] | None = None,
        p_tag: str = "",
        h_tag: str = "",
    ) -> list[dict[str, Any]]:
        if not self.path.is_file():
            return []
        events: list[dict[str, Any]] = []
        for line in self.path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("relay") != relay:
                continue
            if kinds is not None and int(event.get("kind", -1)) not in kinds:
                continue
            if p_tag and not event_has_tag(event, "p", p_tag):
                continue
            if h_tag and not event_has_tag(event, "h", h_tag):
                continue
            events.append(event)
        return events


class NakTransport(Transport):
    def __init__(self, binary: str = "nak") -> None:
        self.binary = binary

    def publish(self, relay: str, event: dict[str, Any]) -> dict[str, Any]:
        self.require_binary()
        secret = str(event.get("_secret") or "")
        if not secret:
            raise WorktreeGuardError("nak transport cannot publish an unsigned event.")
        payload = {key: value for key, value in event.items() if not key.startswith("_")}
        env = os.environ.copy()
        env["NOSTR_SECRET_KEY"] = secret
        try:
            result = subprocess.run(
                [self.binary, "event", "--force-sign", relay],
                input=json.dumps(payload),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=15,
                check=False,
                env=env,
            )
        except subprocess.TimeoutExpired as error:
            raise WorktreeGuardError("nak publish timed out.") from error
        if result.returncode != 0:
            raise WorktreeGuardError(f"nak publish failed: {result.stderr.strip()}")
        published = parse_events(result.stdout)
        if not published or not self.verify(published[-1]):
            raise WorktreeGuardError("nak publish did not return a valid signed event.")
        return published[-1]

    def fetch(
        self,
        relay: str,
        *,
        kinds: set[int] | None = None,
        p_tag: str = "",
        h_tag: str = "",
    ) -> list[dict[str, Any]]:
        self.require_binary()
        args = [self.binary, "req", "--limit", "200"]
        for kind in sorted(kinds or set()):
            args.extend(["-k", str(kind)])
        if p_tag:
            args.extend(["-p", p_tag])
        if h_tag:
            args.extend(["-h", h_tag])
        args.append(relay)
        try:
            result = subprocess.run(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            output = error.stdout or ""
        else:
            if result.returncode != 0:
                raise WorktreeGuardError(f"nak fetch failed: {result.stderr.strip()}")
            output = result.stdout
        return [event for event in parse_events(normalize_output(output)) if self.verify(event)]

    def require_binary(self) -> None:
        if shutil.which(self.binary) is None:
            raise WorktreeGuardError("Remote approval requires `nak` or WTG_TRANSPORT=fake.")

    def verify(self, event: dict[str, Any]) -> bool:
        if not structurally_valid_event(event):
            return False
        try:
            result = subprocess.run(
                [self.binary, "verify"],
                input=json.dumps(event),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return False
        return result.returncode == 0


def transport() -> Transport:
    name = os.environ.get("WTG_TRANSPORT", "nak").strip().lower()
    if name == "fake":
        raw_path = os.environ.get("WTG_FAKE_RELAY_FILE")
        if not raw_path:
            raise WorktreeGuardError("WTG_FAKE_RELAY_FILE is required for fake transport.")
        return FakeTransport(resolve_path(raw_path))
    if name == "nak":
        return NakTransport(os.environ.get("WTG_NAK_BIN", "nak"))
    raise WorktreeGuardError(f"Unsupported WTG_TRANSPORT: {name}")


def poll_events(
    relay: str,
    kinds: set[int],
    deadline: float,
    *,
    p_tag: str = "",
    h_tag: str = "",
) -> list[dict[str, Any]]:
    adapter = transport()
    while True:
        events = adapter.fetch(relay, kinds=kinds, p_tag=p_tag, h_tag=h_tag)
        if events or time.monotonic() >= deadline:
            return events
        time.sleep(0.25)


def parse_events(output: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


def normalize_output(output: str | bytes) -> str:
    return output.decode("utf-8", errors="replace") if isinstance(output, bytes) else output


def event_has_tag(event: dict[str, Any], name: str, value: str) -> bool:
    return any(
        isinstance(tag, list) and len(tag) >= 2 and tag[0] == name and tag[1] == value
        for tag in event.get("tags", [])
    )

"""Nostr transport adapters for tests and real relay use."""

from __future__ import annotations

import hashlib
import json
import secrets
import shutil
import subprocess
import time
from typing import Any

from .errors import RemoteHumanError


class FakeRelayTransport:
    def __init__(self) -> None:
        self._events: list[dict[str, Any]] = []

    def publish(self, event: dict[str, Any]) -> dict[str, Any]:
        prepared = dict(event)
        prepared.setdefault("created_at", int(time.time()))
        prepared.setdefault("tags", [])
        prepared.setdefault("pubkey", "fake-pubkey")
        prepared.setdefault("sig", "fake-signature")
        prepared.setdefault("id", event_id(prepared))
        if not any(existing["id"] == prepared["id"] for existing in self._events):
            self._events.append(prepared)
        return prepared

    def events(self, *, kind: int | None = None) -> list[dict[str, Any]]:
        result = list(self._events)
        if kind is not None:
            result = [event for event in result if event.get("kind") == kind]
        return [dict(event) for event in result]

    def query(self, filters: dict[str, Any]) -> list[dict[str, Any]]:
        result = self.events(kind=filters.get("kind"))
        authors = set(filters.get("authors", []))
        if authors:
            result = [event for event in result if event.get("pubkey") in authors]
        tagged_event = filters.get("#e")
        if tagged_event:
            result = [event for event in result if ["e", tagged_event] in event.get("tags", [])]
        return result

    def generate_secret_key(self) -> str:
        return "fake-nsec-" + secrets.token_hex(16)

    def public_key_for_secret(self, secret_key: str) -> str:
        return "fake-pub-" + hashlib.sha256(secret_key.encode("utf-8")).hexdigest()[:16]


class NakTransport:
    def __init__(self, *, relay_url: str | None = None, nsec: str | None = None, nak_path: str = "nak"):
        self.relay_url = relay_url
        self.nsec = nsec
        self.nak_path = nak_path

    def publish(self, event: dict[str, Any]) -> dict[str, Any]:
        nak = shutil.which(self.nak_path)
        if nak is None:
            raise RemoteHumanError(
                "missing_dependency",
                f"Cannot publish Nostr event because nak is not installed or not executable: {self.nak_path}",
                {"dependency": "nak", "path": self.nak_path},
            )
        if not self.relay_url or not self.nsec:
            raise RemoteHumanError(
                "transport_not_configured",
                "NakTransport requires relay_url and nsec before publishing.",
            )
        command = [
            nak,
            "--sec",
            self.nsec,
            "event",
            "--kind",
            str(event["kind"]),
            "--content",
            str(event.get("content", "")),
        ]
        for tag in event.get("tags", []):
            command.extend(["--tag", format_nak_tag(tag)])
        command.append(self.relay_url)
        completed = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if completed.returncode != 0:
            raise RemoteHumanError(
                "transport_publish_failed",
                "nak failed to publish the Nostr event.",
                {"stderr": completed.stderr.strip()},
            )
        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError:
            published = dict(event)
            published.setdefault("id", event_id(published))
            return published

    def generate_secret_key(self) -> str:
        completed = self._run_key_command(["key", "generate"])
        return completed.stdout.strip()

    def public_key_for_secret(self, secret_key: str) -> str:
        completed = self._run_key_command(["key", "public", secret_key])
        return completed.stdout.strip()

    def _run_key_command(self, arguments: list[str]) -> subprocess.CompletedProcess[str]:
        nak = shutil.which(self.nak_path)
        if nak is None:
            raise RemoteHumanError(
                "missing_dependency",
                f"Cannot manage Nostr keys because nak is not installed or not executable: {self.nak_path}",
                {"dependency": "nak", "path": self.nak_path},
            )
        completed = subprocess.run(
            [nak, *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode != 0:
            raise RemoteHumanError(
                "transport_key_failed",
                "nak failed to manage the backend key.",
                {"stderr": completed.stderr.strip()},
            )
        return completed


def format_nak_tag(tag: list[Any]) -> str:
    if not tag:
        return ""
    if len(tag) == 1:
        return str(tag[0])
    return f"{tag[0]}=" + ";".join(str(part) for part in tag[1:])


def event_id(event: dict[str, Any]) -> str:
    payload = json.dumps(
        {
            "kind": event.get("kind"),
            "pubkey": event.get("pubkey"),
            "content": event.get("content", ""),
            "tags": event.get("tags", []),
            "created_at": event.get("created_at", 0),
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()

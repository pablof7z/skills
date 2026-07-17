#!/usr/bin/env python3
"""Persistent OAuth clients and rotating tokens for TTS MCP."""

from __future__ import annotations

import asyncio
import hashlib
import ipaddress
import json
from pathlib import Path
import secrets
import time
from urllib.parse import urlparse

from mcp.server.auth.provider import AccessToken, RefreshToken, RegistrationError
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken

from tts_remote_state import read_json, tts_state_dir, write_json


ACCESS_TOKEN_TTL_SECONDS = 3600
REFRESH_TOKEN_TTL_SECONDS = 30 * 24 * 3600
MAX_CLIENTS = 100


class StoredAccessToken(AccessToken):
    pair_id: str


class StoredRefreshToken(RefreshToken):
    pair_id: str


class OAuthTokenStore:
    def __init__(self, resource_url: str, path: Path | None = None) -> None:
        self.resource_url = resource_url
        self.path = path or (tts_state_dir() / "mcp" / "oauth-store.json")
        self.lock = asyncio.Lock()

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        value = self._state()["clients"].get(client_id)
        return (
            OAuthClientInformationFull.model_validate(value)
            if isinstance(value, dict)
            else None
        )

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        client_id = str(client_info.client_id or "")
        serialized = client_info.model_dump(mode="json")
        if not client_id or len(json.dumps(serialized)) > 16_384:
            raise RegistrationError(
                "invalid_client_metadata", "Client metadata is too large"
            )
        for redirect in client_info.redirect_uris or []:
            if not valid_redirect_uri(str(redirect)):
                raise RegistrationError(
                    "invalid_redirect_uri",
                    "Redirect URIs must use HTTPS or loopback HTTP and must not contain fragments",
                )
        async with self.lock:
            state = self._state()
            clients = state["clients"]
            if len(clients) >= MAX_CLIENTS and client_id not in clients:
                oldest = min(
                    clients,
                    key=lambda key: int(clients[key].get("client_id_issued_at") or 0),
                )
                clients.pop(oldest, None)
            clients[client_id] = serialized
            self._save(state)

    async def load_refresh(
        self,
        client: OAuthClientInformationFull,
        value: str,
    ) -> StoredRefreshToken | None:
        raw = self._state()["refresh_tokens"].get(token_hash(value))
        token = (
            StoredRefreshToken.model_validate(raw) if isinstance(raw, dict) else None
        )
        if (
            token
            and token.client_id == client.client_id
            and not expired(token.expires_at)
        ):
            return token
        return None

    async def load_access(self, value: str) -> StoredAccessToken | None:
        raw = self._state()["access_tokens"].get(token_hash(value))
        token = StoredAccessToken.model_validate(raw) if isinstance(raw, dict) else None
        if (
            token
            and not expired(token.expires_at)
            and token.resource == self.resource_url
        ):
            return token
        return None

    async def issue(
        self,
        client_id: str,
        scopes: list[str],
        resource: str,
    ) -> OAuthToken:
        now = int(time.time())
        pair_id = secrets.token_urlsafe(16)
        access_value = secrets.token_urlsafe(32)
        refresh_value = secrets.token_urlsafe(32)
        access = StoredAccessToken(
            token=access_value,
            client_id=client_id,
            scopes=scopes,
            expires_at=now + ACCESS_TOKEN_TTL_SECONDS,
            resource=resource,
            subject="tts-owner",
            pair_id=pair_id,
        )
        refresh = StoredRefreshToken(
            token=refresh_value,
            client_id=client_id,
            scopes=scopes,
            expires_at=now + REFRESH_TOKEN_TTL_SECONDS,
            subject="tts-owner",
            pair_id=pair_id,
        )
        async with self.lock:
            state = self._state()
            prune_tokens(state, now)
            state["access_tokens"][token_hash(access_value)] = access.model_dump(
                mode="json"
            )
            state["refresh_tokens"][token_hash(refresh_value)] = refresh.model_dump(
                mode="json"
            )
            self._save(state)
        return OAuthToken(
            access_token=access_value,
            expires_in=ACCESS_TOKEN_TTL_SECONDS,
            scope=" ".join(scopes),
            refresh_token=refresh_value,
        )

    async def revoke(self, token: StoredAccessToken | StoredRefreshToken) -> None:
        async with self.lock:
            state = self._state()
            for collection in (state["access_tokens"], state["refresh_tokens"]):
                for key, value in list(collection.items()):
                    if (
                        isinstance(value, dict)
                        and value.get("pair_id") == token.pair_id
                    ):
                        collection.pop(key, None)
            self._save(state)

    def _state(self) -> dict[str, dict[str, object]]:
        value = read_json(self.path, {})
        if not isinstance(value, dict):
            value = {}
        return {
            "clients": dict(value.get("clients") or {}),
            "access_tokens": dict(value.get("access_tokens") or {}),
            "refresh_tokens": dict(value.get("refresh_tokens") or {}),
        }

    def _save(self, state: dict[str, dict[str, object]]) -> None:
        write_json(self.path, state)


def valid_redirect_uri(value: str) -> bool:
    parsed = urlparse(value)
    if parsed.fragment or not parsed.hostname:
        return False
    if parsed.scheme == "https":
        return True
    if parsed.scheme != "http":
        return False
    if parsed.hostname == "localhost":
        return True
    try:
        return ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        return False


def token_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def expired(value: int | None) -> bool:
    return value is not None and value <= int(time.time())


def prune_tokens(state: dict[str, dict[str, object]], now: int) -> None:
    for name in ("access_tokens", "refresh_tokens"):
        collection = state[name]
        for key, value in list(collection.items()):
            if not isinstance(value, dict) or int(value.get("expires_at") or 0) <= now:
                collection.pop(key, None)

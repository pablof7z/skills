#!/usr/bin/env python3
"""OAuth 2.1 provider gated by a short local TTS pairing code."""

from __future__ import annotations

from pathlib import Path
import secrets
import time
from urllib.parse import quote, urlparse

from mcp.server.auth.provider import (
    AuthorizationCode,
    AuthorizationParams,
    AuthorizeError,
    OAuthAuthorizationServerProvider,
    TokenError,
    construct_redirect_uri,
)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken

from tts_mcp_pairing import PairingCodeStore
from tts_mcp_oauth_tokens import OAuthTokenStore, StoredAccessToken, StoredRefreshToken


SCOPE = "tts:use"
AUTHORIZATION_TTL_SECONDS = 300


class PairingApprovalError(RuntimeError):
    def __init__(self, message: str, status_code: int = 400) -> None:
        super().__init__(message)
        self.status_code = status_code


class PairingOAuthProvider(
    OAuthAuthorizationServerProvider[
        AuthorizationCode, StoredRefreshToken, StoredAccessToken
    ]
):
    def __init__(
        self,
        issuer_url: str,
        resource_url: str,
        pairing: PairingCodeStore,
        state_path: Path | None = None,
    ) -> None:
        self.issuer_url = issuer_url.rstrip("/")
        self.resource_url = resource_url
        self.pairing = pairing
        self.tokens = OAuthTokenStore(resource_url, state_path)
        self.pending: dict[str, dict[str, object]] = {}
        self.codes: dict[str, AuthorizationCode] = {}

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        return await self.tokens.get_client(client_id)

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        await self.tokens.register_client(client_info)

    async def authorize(
        self,
        client: OAuthClientInformationFull,
        params: AuthorizationParams,
    ) -> str:
        if params.resource != self.resource_url:
            raise AuthorizeError(
                "invalid_request",
                "The resource parameter must identify this MCP endpoint",
            )
        scopes = params.scopes or [SCOPE]
        if scopes != [SCOPE]:
            raise AuthorizeError("invalid_scope", f"Only {SCOPE} is supported")
        request_id = secrets.token_urlsafe(32)
        self.pending[request_id] = {
            "client": client,
            "params": params,
            "expires_at": time.time() + AUTHORIZATION_TTL_SECONDS,
        }
        return f"{self.issuer_url}/pair?request={quote(request_id)}"

    def pending_expiry(self, request_id: str) -> int:
        pending = self.pending.get(request_id)
        if not pending or float(pending["expires_at"]) <= time.time():
            self.pending.pop(request_id, None)
            raise PairingApprovalError("This authorization request has expired.", 410)
        return int(pending["expires_at"])

    def pending_summary(self, request_id: str) -> dict[str, object]:
        expires_at = self.pending_expiry(request_id)
        pending = self.pending[request_id]
        client = pending.get("client")
        params = pending.get("params")
        if not isinstance(client, OAuthClientInformationFull) or not isinstance(
            params, AuthorizationParams
        ):
            raise PairingApprovalError("The authorization request is invalid.")
        redirect_uri = urlparse(str(params.redirect_uri))
        return {
            "expires_at": expires_at,
            "client_name": client.client_name or "Unnamed MCP caller",
            "redirect_host": redirect_uri.hostname or "unknown",
            "redirect_origin": f"{redirect_uri.scheme}://{redirect_uri.netloc}",
        }

    async def complete_authorization(self, request_id: str, submitted_code: str) -> str:
        self.pending_expiry(request_id)
        approved, reason = self.pairing.verify_and_consume(submitted_code)
        if not approved:
            status = 429 if reason == "rate_limited" else 401
            message = {
                "expired": "The pairing code expired; use the new code shown by tts-mcp.",
                "rate_limited": "Too many incorrect attempts; tts-mcp generated a new code.",
            }.get(reason, "The pairing code is incorrect.")
            raise PairingApprovalError(message, status)
        pending = self.pending.pop(request_id)
        client = pending["client"]
        params = pending["params"]
        if not isinstance(client, OAuthClientInformationFull) or not isinstance(
            params, AuthorizationParams
        ):
            raise PairingApprovalError("The authorization request is invalid.")
        code = secrets.token_urlsafe(32)
        self.codes[code] = AuthorizationCode(
            code=code,
            scopes=params.scopes or [SCOPE],
            expires_at=time.time() + AUTHORIZATION_TTL_SECONDS,
            client_id=str(client.client_id),
            code_challenge=params.code_challenge,
            redirect_uri=params.redirect_uri,
            redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
            resource=params.resource,
            subject="tts-owner",
        )
        return construct_redirect_uri(
            str(params.redirect_uri), code=code, state=params.state
        )

    async def load_authorization_code(
        self,
        client: OAuthClientInformationFull,
        authorization_code: str,
    ) -> AuthorizationCode | None:
        value = self.codes.get(authorization_code)
        return value if value and value.client_id == client.client_id else None

    async def exchange_authorization_code(
        self,
        client: OAuthClientInformationFull,
        authorization_code: AuthorizationCode,
    ) -> OAuthToken:
        if self.codes.pop(authorization_code.code, None) is None:
            raise TokenError("invalid_grant", "Authorization code was already used")
        return await self.tokens.issue(
            str(client.client_id),
            authorization_code.scopes,
            authorization_code.resource or self.resource_url,
        )

    async def load_refresh_token(
        self,
        client: OAuthClientInformationFull,
        refresh_token: str,
    ) -> StoredRefreshToken | None:
        return await self.tokens.load_refresh(client, refresh_token)

    async def exchange_refresh_token(
        self,
        client: OAuthClientInformationFull,
        refresh_token: StoredRefreshToken,
        scopes: list[str],
    ) -> OAuthToken:
        if any(scope not in refresh_token.scopes for scope in scopes):
            raise TokenError(
                "invalid_scope", "Refresh scope exceeds the original grant"
            )
        await self.tokens.revoke(refresh_token)
        return await self.tokens.issue(str(client.client_id), scopes, self.resource_url)

    async def load_access_token(self, token: str) -> StoredAccessToken | None:
        return await self.tokens.load_access(token)

    async def revoke_token(self, token: StoredAccessToken | StoredRefreshToken) -> None:
        await self.tokens.revoke(token)

#!/usr/bin/env python3
"""CLI and HTTP runtime assembly for TTS MCP."""

from __future__ import annotations

import argparse
import hmac
import ipaddress
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlparse

from mcp.server.auth.settings import (
    AuthSettings,
    ClientRegistrationOptions,
    RevocationOptions,
)
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import AnyHttpUrl
from starlette.responses import JSONResponse
from starlette.routing import Route

from tts_mcp_config import MCPConfig
from tts_mcp_http_log import HeaderAuditMiddleware, HeaderTrafficStore
from tts_mcp_oauth import PairingOAuthProvider, SCOPE
from tts_mcp_oauth_routes import oauth_extra_routes
from tts_mcp_pairing import PairingCodeStore


class BearerAuthMiddleware:
    def __init__(self, app, token: str) -> None:
        self.app = app
        self.token = token

    async def __call__(self, scope, receive, send) -> None:
        if scope.get("type") == "http" and scope.get("path") != "/healthz":
            headers = {key.lower(): value for key, value in scope.get("headers", [])}
            supplied = headers.get(b"authorization", b"").decode(
                "utf-8", errors="ignore"
            )
            if not hmac.compare_digest(supplied, f"Bearer {self.token}"):
                response = JSONResponse(
                    {"error": "unauthorized"},
                    status_code=401,
                    headers={"WWW-Authenticate": "Bearer"},
                )
                await response(scope, receive, send)
                return
        await self.app(scope, receive, send)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="tts-mcp")
    parser.add_argument("command", nargs="?", choices=["pairing-code", "headers"])
    parser.add_argument(
        "--http", action="store_true", help="serve Streamable HTTP instead of stdio"
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8781)
    parser.add_argument("--path", default="/mcp")
    parser.add_argument(
        "--public-url", help="public HTTPS origin; enables pairing-code OAuth"
    )
    parser.add_argument("--token-env", default="TTS_MCP_TOKEN")
    parser.add_argument("--allow-origin", action="append", default=[])
    parser.add_argument("--allow-root", action="append", default=[])
    parser.add_argument(
        "--route", choices=["automatic", "paired", "local"], default="automatic"
    )
    parser.add_argument(
        "--rotate", action="store_true", help="replace the current pairing code"
    )
    parser.add_argument(
        "--limit", type=int, default=50, help="header entries returned by headers"
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.command == "pairing-code":
        value = (
            PairingCodeStore().rotate() if args.rotate else PairingCodeStore().current()
        )
        print(json.dumps(value.public_dict(), indent=2, sort_keys=True))
        return 0
    if args.command == "headers":
        print(
            json.dumps(
                HeaderTrafficStore().recent(args.limit), indent=2, sort_keys=True
            )
        )
        return 0
    skill_dir = Path(__file__).resolve().parents[1]
    config = MCPConfig(
        skill_dir=skill_dir,
        route=args.route,
        allowed_roots=tuple(valid_root(value) for value in args.allow_root),
    )
    from tts_mcp_server import build_server

    if not args.http:
        build_server(config).run(transport="stdio")
        return 0
    validate_http_args(args)
    origin = normalized_public_origin(args.public_url) if args.public_url else None
    public_host = urlparse(origin).hostname if origin else None
    allowed_hosts = ["127.0.0.1:*", "localhost:*", "[::1]:*"]
    if public_host:
        allowed_hosts.extend([public_host, f"{public_host}:*"])
    allowed_origins = ["http://127.0.0.1:*", "http://localhost:*", *args.allow_origin]
    if origin:
        allowed_origins.append(origin)
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=allowed_hosts,
        allowed_origins=allowed_origins,
    )
    provider = oauth_provider(origin, args.path) if origin else None
    auth = auth_settings(provider) if provider else None
    server = build_server(config, security=security, auth=auth, provider=provider)
    server.settings.streamable_http_path = args.path
    app = server.streamable_http_app()
    app.routes.append(
        Route(
            "/healthz",
            lambda _request: JSONResponse({"status": "ok"}),
        )
    )
    if provider:
        app.routes.extend(oauth_extra_routes(provider))
        pairing = provider.pairing.rotate()
        print_pairing_code(pairing.public_dict())
        protected_app = app
    else:
        token = os.environ.get(args.token_env, "")
        if len(token) < 24:
            raise SystemExit(
                f"{args.token_env} must contain a bearer token of at least 24 characters"
            )
        protected_app = BearerAuthMiddleware(app, token)
    import uvicorn

    uvicorn.run(
        HeaderAuditMiddleware(protected_app),
        host=args.host,
        port=args.port,
        log_level="info",
        access_log=False,
    )
    return 0


def oauth_provider(origin: str, path: str) -> PairingOAuthProvider:
    return PairingOAuthProvider(
        issuer_url=origin,
        resource_url=f"{origin}{path}",
        pairing=PairingCodeStore(),
    )


def auth_settings(provider: PairingOAuthProvider) -> AuthSettings:
    return AuthSettings(
        issuer_url=AnyHttpUrl(provider.issuer_url),
        resource_server_url=AnyHttpUrl(provider.resource_url),
        required_scopes=[SCOPE],
        client_registration_options=ClientRegistrationOptions(
            enabled=True,
            client_secret_expiry_seconds=24 * 3600,
            valid_scopes=[SCOPE],
            default_scopes=[SCOPE],
        ),
        revocation_options=RevocationOptions(enabled=True),
    )


def normalized_public_origin(value: str) -> str:
    parsed = urlparse(value.rstrip("/"))
    loopback_http = parsed.scheme == "http" and loopback_host(parsed.hostname)
    if (parsed.scheme != "https" and not loopback_http) or not parsed.hostname:
        raise SystemExit("--public-url must be an HTTPS origin")
    if (
        parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
        or parsed.username
        or parsed.password
    ):
        raise SystemExit(
            "--public-url must not contain a path, credentials, query, or fragment"
        )
    return value.rstrip("/")


def valid_root(value: str) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise SystemExit(f"allowed root is not a directory: {value}")
    return path


def validate_http_args(args: argparse.Namespace) -> None:
    if args.command:
        raise SystemExit("commands cannot be combined with --http")
    if args.host != "localhost" and not loopback_host(args.host):
        raise SystemExit(
            "HTTP mode only supports loopback hosts; use a reverse tunnel for public access"
        )
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be between 1 and 65535")
    if not args.path.startswith("/") or "//" in args.path or args.path == "/":
        raise SystemExit("path must be a non-root absolute URL path")


def loopback_host(value: str | None) -> bool:
    if value == "localhost":
        return True
    try:
        return bool(value and ipaddress.ip_address(value).is_loopback)
    except ValueError:
        return False


def print_pairing_code(value: dict[str, object]) -> None:
    print(
        f"TTS MCP pairing code: {value['code']} "
        f"(expires at {value['expires_at']}; TTL {value['ttl_seconds']} seconds)",
        file=sys.stderr,
        flush=True,
    )

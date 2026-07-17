#!/usr/bin/env python3
"""MCP tools for spoken TTS, paired delivery, and Blossom generation."""

from __future__ import annotations

import argparse
import hmac
import ipaddress
import json
import os
from pathlib import Path
import sys

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from starlette.responses import JSONResponse
from starlette.routing import Route

from tts_mcp_adapter import TTSAdapter
from tts_mcp_config import MCPConfig
from tts_mcp_models import AttachmentInput, ItemFilters, QuestionBundleInput
from tts_mcp_state import item_attachment, item_audio, item_json


def build_server(config: MCPConfig, security: TransportSecuritySettings | None = None) -> FastMCP:
    adapter = TTSAdapter(config)
    server = FastMCP(
        "TTS",
        instructions=(
            "Create spoken updates, ask answerable spoken questions, inspect durable state, or "
            "generate a no-play MP3 hosted on Blossom. The configured route decides whether "
            "requests run locally or on the paired TTS computer."
        ),
        json_response=True,
        stateless_http=True,
        transport_security=security,
    )

    @server.tool(name="tts_speak", annotations=write_annotation(idempotent=False))
    async def tts_speak(
        agent_name: str,
        subject: str,
        message: str,
        attachments: list[AttachmentInput] | None = None,
    ) -> dict[str, object]:
        """Generate and queue an audible spoken update on the configured TTS computer."""
        return await adapter.speak(
            agent_name=agent_name,
            subject=subject,
            message=message,
            attachments=attachments or [],
        )

    @server.tool(name="tts_ask", annotations=write_annotation(idempotent=False))
    async def tts_ask(
        agent_name: str,
        subject: str,
        message: str,
        bundle: QuestionBundleInput,
        wait_seconds: int = 300,
        attachments: list[AttachmentInput] | None = None,
    ) -> dict[str, object]:
        """Speak an update, show one to three optional questions, and wait for a bounded answer."""
        bounded_seconds(wait_seconds, "wait_seconds")
        return await adapter.ask(
            agent_name=agent_name,
            subject=subject,
            message=message,
            bundle=bundle,
            wait_seconds=wait_seconds,
            attachments=attachments or [],
        )

    @server.tool(
        name="tts_generate",
        annotations=ToolAnnotations(
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=False,
            openWorldHint=True,
        ),
    )
    async def tts_generate(
        agent_name: str,
        subject: str,
        message: str,
        wait_seconds: int = 300,
    ) -> dict[str, object]:
        """Generate without playback, upload to blossom.primal.net, and return its hosted descriptor."""
        bounded_seconds(wait_seconds, "wait_seconds")
        return await adapter.generate(
            agent_name=agent_name,
            subject=subject,
            message=message,
            wait_seconds=wait_seconds,
        )

    @server.tool(name="tts_status", annotations=read_only())
    async def tts_status() -> dict[str, object]:
        """Inspect current playback, queued speech, recent outcomes, and app state."""
        return await adapter.status()

    @server.tool(name="tts_health", annotations=read_only())
    async def tts_health() -> dict[str, object]:
        """Check the route, playback destination, Blossom target, and player health."""
        return await adapter.health()

    @server.tool(name="tts_list_items", annotations=read_only())
    async def tts_list_items(filters: ItemFilters | None = None) -> dict[str, object]:
        """List a bounded page of active or archived durable TTS items."""
        return await adapter.list_items(filters or ItemFilters())

    @server.tool(name="tts_get_item", annotations=read_only())
    async def tts_get_item(item_id: str) -> dict[str, object]:
        """Get one durable TTS item without exposing host filesystem paths."""
        return await adapter.get_item(item_id)

    @server.tool(name="tts_wait_for_item", annotations=read_only())
    async def tts_wait_for_item(item_id: str, timeout_seconds: int) -> dict[str, object]:
        """Wait for an answer or terminal playback state for a bounded interval."""
        bounded_seconds(timeout_seconds, "timeout_seconds")
        return await adapter.wait_for_item(item_id, timeout_seconds)

    @server.tool(name="tts_archive_items", annotations=write_annotation())
    async def tts_archive_items(
        ids: list[str], reason: str, actor: str | None = None,
    ) -> dict[str, object]:
        """Archive one or more durable items without deleting their records."""
        require_ids(ids)
        return await adapter.archive(ids, reason, actor)

    @server.tool(name="tts_restore_items", annotations=write_annotation())
    async def tts_restore_items(
        ids: list[str], reason: str = "Restored through MCP.", actor: str | None = None,
    ) -> dict[str, object]:
        """Restore one or more archived durable items."""
        require_ids(ids)
        return await adapter.restore(ids, reason, actor)

    @server.tool(
        name="tts_supersede_questions",
        annotations=ToolAnnotations(
            readOnlyHint=False,
            destructiveHint=True,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )
    async def tts_supersede_questions(
        ids: list[str], replacements: list[str], reason: str, actor: str | None = None,
    ) -> dict[str, object]:
        """Atomically supersede pending questions with replacement item IDs."""
        require_ids(ids)
        require_ids(replacements)
        return await adapter.supersede(ids, replacements, reason, actor)

    @server.resource("tts://status", mime_type="application/json")
    async def status_resource() -> str:
        return json.dumps(await adapter.status(), ensure_ascii=False, indent=2, sort_keys=True)

    @server.resource("tts://health", mime_type="application/json")
    async def health_resource() -> str:
        return json.dumps(await adapter.health(), ensure_ascii=False, indent=2, sort_keys=True)

    @server.resource("tts://items/{item_id}", mime_type="application/json")
    def item_resource(item_id: str) -> str:
        return item_json(item_id)

    @server.resource("tts://items/{item_id}/audio", mime_type="audio/mpeg")
    def audio_resource(item_id: str) -> bytes:
        return item_audio(item_id)

    @server.resource(
        "tts://items/{item_id}/attachments/{index}",
        mime_type="application/octet-stream",
    )
    def attachment_resource(item_id: str, index: str) -> bytes:
        return item_attachment(item_id, index)[0]

    return server


def read_only() -> ToolAnnotations:
    return ToolAnnotations(
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    )


def write_annotation(*, idempotent: bool = True) -> ToolAnnotations:
    return ToolAnnotations(
        readOnlyHint=False,
        destructiveHint=False,
        idempotentHint=idempotent,
        openWorldHint=False,
    )


def require_ids(ids: list[str]) -> None:
    if not ids or len(ids) > 100 or any(not value for value in ids):
        raise ValueError("ids must contain between 1 and 100 non-empty identifiers")


def bounded_seconds(value: int, name: str) -> None:
    if not 1 <= value <= 3600:
        raise ValueError(f"{name} must be between 1 and 3600")


class BearerAuthMiddleware:
    def __init__(self, app, token: str) -> None:
        self.app = app
        self.token = token

    async def __call__(self, scope, receive, send) -> None:
        if scope.get("type") == "http" and scope.get("path") != "/healthz":
            headers = {key.lower(): value for key, value in scope.get("headers", [])}
            supplied = headers.get(b"authorization", b"").decode("utf-8", errors="ignore")
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
    parser.add_argument("--http", action="store_true", help="serve Streamable HTTP instead of stdio")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8781)
    parser.add_argument("--path", default="/mcp")
    parser.add_argument("--token-env", default="TTS_MCP_TOKEN")
    parser.add_argument("--allow-origin", action="append", default=[])
    parser.add_argument("--allow-root", action="append", default=[])
    parser.add_argument("--route", choices=["automatic", "paired", "local"], default="automatic")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    skill_dir = Path(__file__).resolve().parents[1]
    config = MCPConfig(
        skill_dir=skill_dir,
        route=args.route,
        allowed_roots=tuple(valid_root(value) for value in args.allow_root),
    )
    if not args.http:
        build_server(config).run(transport="stdio")
        return 0
    validate_http_args(args)
    token = os.environ.get(args.token_env, "")
    if len(token) < 24:
        raise SystemExit(f"{args.token_env} must contain a bearer token of at least 24 characters")
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=["127.0.0.1:*", "localhost:*", "[::1]:*"],
        allowed_origins=["http://127.0.0.1:*", "http://localhost:*", *args.allow_origin],
    )
    server = build_server(config, security)
    server.settings.streamable_http_path = args.path
    app = server.streamable_http_app()
    app.routes.append(Route("/healthz", lambda _request: JSONResponse({"status": "ok"})))
    import uvicorn
    uvicorn.run(BearerAuthMiddleware(app, token), host=args.host, port=args.port, log_level="info")
    return 0


def valid_root(value: str) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise SystemExit(f"allowed root is not a directory: {value}")
    return path


def validate_http_args(args: argparse.Namespace) -> None:
    try:
        if args.host != "localhost" and not ipaddress.ip_address(args.host).is_loopback:
            raise ValueError
    except ValueError as error:
        raise SystemExit("HTTP mode only supports loopback hosts; public hosting requires OAuth") from error
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be between 1 and 65535")
    if not args.path.startswith("/") or "//" in args.path or args.path == "/":
        raise SystemExit("path must be a non-root absolute URL path")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

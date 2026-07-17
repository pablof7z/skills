#!/usr/bin/env python3
"""OAuth pairing, PKCE, metadata, and header-monitoring contracts."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlparse

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "tts" / "scripts"
sys.path.insert(0, str(SCRIPTS))

from tts_mcp_pairing import (  # noqa: E402
    MAX_FAILED_ATTEMPTS,
    PAIRING_TTL_SECONDS,
    PairingCodeStore,
)


SERVER = ROOT / "tts" / "scripts" / "tts_mcp_server.py"


class PairingCodeTests(unittest.TestCase):
    def test_code_is_four_characters_one_use_and_exactly_five_minutes(self) -> None:
        now = [1_000.0]
        with tempfile.TemporaryDirectory(prefix="tts-pairing-code-") as temporary:
            store = PairingCodeStore(
                Path(temporary) / "pairing.json", clock=lambda: now[0]
            )
            first = store.rotate()
            self.assertEqual(len(first.code), 4)
            self.assertEqual(first.expires_at - first.created_at, PAIRING_TTL_SECONDS)
            self.assertEqual(store.verify_and_consume(first.code), (True, "approved"))
            self.assertFalse(store.verify_and_consume(first.code)[0])

    def test_expiry_and_failed_attempt_limit_rotate_the_code(self) -> None:
        now = [1_000.0]
        with tempfile.TemporaryDirectory(prefix="tts-pairing-expiry-") as temporary:
            store = PairingCodeStore(
                Path(temporary) / "pairing.json", clock=lambda: now[0]
            )
            first = store.rotate()
            now[0] += PAIRING_TTL_SECONDS + 1
            self.assertEqual(store.verify_and_consume(first.code)[1], "expired")
            current = store.current()
            for _attempt in range(MAX_FAILED_ATTEMPTS - 1):
                self.assertEqual(store.verify_and_consume("0000")[1], "invalid")
            self.assertEqual(store.verify_and_consume("0000")[1], "rate_limited")
            self.assertNotEqual(store.current().code, current.code)


class MCPOAuthHTTPTests(unittest.TestCase):
    def test_pairing_code_oauth_flow_and_redacted_header_traffic(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-mcp-oauth-") as temporary:
            root = Path(temporary)
            port = available_port()
            origin = f"http://127.0.0.1:{port}"
            environment = os.environ.copy()
            environment.update(
                {
                    "HOME": str(root / "home"),
                    "TTS_STATE_DIR": str(root / "state"),
                    "TTS_REMOTE_NO_MENU": "1",
                }
            )
            Path(environment["HOME"]).mkdir()
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(SERVER),
                    "--http",
                    "--public-url",
                    origin,
                    "--port",
                    str(port),
                    "--route",
                    "local",
                ],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                wait_for_server(origin, process)
                self.run_oauth_contract(origin, root)
            finally:
                process.terminate()
                try:
                    _stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    _stdout, stderr = process.communicate(timeout=2)
            self.assertIn("TTL 300 seconds", stderr)
            self.assert_header_log(root)

    def run_oauth_contract(self, origin: str, root: Path) -> None:
        resource = f"{origin}/mcp"
        root_metadata = httpx.get(f"{origin}/.well-known/oauth-protected-resource")
        self.assertEqual(root_metadata.status_code, 200)
        self.assertEqual(root_metadata.json()["resource"], resource)
        path_metadata = httpx.get(f"{origin}/.well-known/oauth-protected-resource/mcp")
        self.assertEqual(path_metadata.status_code, 200)
        authorization_metadata = httpx.get(
            f"{origin}/.well-known/oauth-authorization-server"
        )
        self.assertEqual(authorization_metadata.status_code, 200)
        self.assertEqual(
            authorization_metadata.json()["code_challenge_methods_supported"], ["S256"]
        )
        callback = "http://127.0.0.1:45454/callback"
        registration = httpx.post(
            f"{origin}/register",
            json={
                "redirect_uris": [callback],
                "token_endpoint_auth_method": "none",
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "client_name": "TTS MCP test caller",
                "scope": "tts:use",
            },
        )
        self.assertEqual(registration.status_code, 201, registration.text)
        client_id = registration.json()["client_id"]
        verifier = secrets.token_urlsafe(48)
        challenge = (
            base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
            .decode()
            .rstrip("=")
        )
        authorization = httpx.get(
            f"{origin}/authorize",
            params={
                "client_id": client_id,
                "redirect_uri": callback,
                "response_type": "code",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "state": "test-state",
                "scope": "tts:use",
                "resource": resource,
            },
            follow_redirects=False,
        )
        self.assertEqual(authorization.status_code, 302, authorization.text)
        pair_url = authorization.headers["location"]
        request_id = parse_qs(urlparse(pair_url).query)["request"][0]
        pairing = json.loads(
            (root / "state" / "mcp" / "oauth-pairing.json").read_text()
        )
        pair_html = httpx.get(pair_url).text
        self.assertNotIn(pairing["code"], pair_html)
        self.assertIn("TTS MCP test caller", pair_html)
        self.assertIn("127.0.0.1", pair_html)
        approved = httpx.post(
            f"{origin}/pair",
            data={"request": request_id, "pairing_code": pairing["code"]},
            follow_redirects=False,
        )
        self.assertEqual(approved.status_code, 303, approved.text)
        callback_values = parse_qs(urlparse(approved.headers["location"]).query)
        self.assertEqual(callback_values["state"], ["test-state"])
        token = httpx.post(
            f"{origin}/token",
            data={
                "grant_type": "authorization_code",
                "code": callback_values["code"][0],
                "redirect_uri": callback,
                "client_id": client_id,
                "code_verifier": verifier,
                "resource": resource,
            },
        )
        self.assertEqual(token.status_code, 200, token.text)
        access_token = token.json()["access_token"]
        unauthenticated = httpx.post(
            resource,
            headers={
                "Accept": "application/json, text/event-stream",
                "X-Debug-Caller": "oauth-contract",
            },
            json={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        )
        self.assertEqual(unauthenticated.status_code, 401)
        self.assertIn("resource_metadata=", unauthenticated.headers["www-authenticate"])
        asyncio.run(self.verify_mcp(resource, access_token))

    async def verify_mcp(self, resource: str, access_token: str) -> None:
        headers = {
            "Authorization": f"Bearer {access_token}",
            "X-Debug-Caller": "oauth-mcp",
        }
        async with httpx.AsyncClient(headers=headers) as client:
            async with streamable_http_client(resource, http_client=client) as streams:
                async with ClientSession(streams[0], streams[1]) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    self.assertIn(
                        "tts_http_header_traffic", {tool.name for tool in tools.tools}
                    )
                    traffic = await session.call_tool(
                        "tts_http_header_traffic", {"limit": 100}
                    )
                    self.assertFalse(traffic.isError)

    def assert_header_log(self, root: Path) -> None:
        path = root / "state" / "mcp" / "http-headers.jsonl"
        entries = [json.loads(line) for line in path.read_text().splitlines()]
        self.assertTrue(
            any(
                item["headers"].get("x-debug-caller") == "oauth-mcp" for item in entries
            )
        )
        authorization = [
            item["headers"]["authorization"]
            for item in entries
            if "authorization" in item["headers"]
        ]
        self.assertTrue(authorization)
        self.assertTrue(
            all(
                "<redacted:" in value and "Bearer ey" not in value
                for value in authorization
            )
        )
        self.assertTrue(all("test-state" not in json.dumps(item) for item in entries))


def available_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def wait_for_server(origin: str, process: subprocess.Popen[str]) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            _stdout, stderr = process.communicate()
            raise AssertionError(f"OAuth MCP server exited early: {stderr}")
        try:
            if httpx.get(f"{origin}/healthz", timeout=0.5).status_code == 200:
                return
        except httpx.HTTPError:
            pass
        time.sleep(0.05)
    raise AssertionError("OAuth MCP server did not become ready")


if __name__ == "__main__":
    unittest.main()

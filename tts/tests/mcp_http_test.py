#!/usr/bin/env python3
"""Authenticated loopback Streamable HTTP contracts for TTS MCP."""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "tts" / "scripts" / "tts_mcp_server.py"
TOKEN = "test-token-with-at-least-24-characters"


class MCPHTTPTests(unittest.TestCase):
    def test_authenticated_streamable_http_and_request_guards(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-mcp-http-") as temporary:
            port = available_port()
            environment = os.environ.copy()
            environment.update({
                "HOME": str(Path(temporary) / "home"),
                "TTS_STATE_DIR": str(Path(temporary) / "state"),
                "TTS_MCP_TOKEN": TOKEN,
                "TTS_REMOTE_NO_MENU": "1",
            })
            Path(environment["HOME"]).mkdir()
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(SERVER),
                    "--http",
                    "--port", str(port),
                    "--route", "local",
                ],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            url = f"http://127.0.0.1:{port}"
            try:
                wait_for_server(url, process)
                self.assertEqual(httpx.get(f"{url}/healthz").json(), {"status": "ok"})
                unauthenticated = httpx.post(
                    f"{url}/mcp",
                    headers={"Accept": "application/json, text/event-stream"},
                    json={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                )
                self.assertEqual(unauthenticated.status_code, 401)
                hostile_origin = httpx.post(
                    f"{url}/mcp",
                    headers={
                        "Authorization": f"Bearer {TOKEN}",
                        "Origin": "https://attacker.example",
                        "Accept": "application/json, text/event-stream",
                    },
                    json={"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                )
                self.assertEqual(hostile_origin.status_code, 403)
                asyncio.run(self._mcp_contract(f"{url}/mcp"))
            finally:
                process.terminate()
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=2)

    async def _mcp_contract(self, url: str) -> None:
        async with httpx.AsyncClient(headers={"Authorization": f"Bearer {TOKEN}"}) as client:
            async with streamable_http_client(url, http_client=client) as streams:
                async with ClientSession(streams[0], streams[1]) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    self.assertIn("tts_generate", {tool.name for tool in tools.tools})
                    health = await session.call_tool("tts_health", {})
                    self.assertFalse(health.isError)
                    self.assertEqual(health.structuredContent["route"], "local")


def available_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def wait_for_server(url: str, process: subprocess.Popen[str]) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            _stdout, stderr = process.communicate()
            raise AssertionError(f"MCP HTTP server exited early: {stderr}")
        try:
            if httpx.get(f"{url}/healthz", timeout=0.5).status_code == 200:
                return
        except httpx.HTTPError:
            pass
        time.sleep(0.05)
    raise AssertionError("MCP HTTP server did not become ready")


if __name__ == "__main__":
    unittest.main()

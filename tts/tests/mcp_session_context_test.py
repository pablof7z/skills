#!/usr/bin/env python3
"""Request-scoped MCP session attribution contracts."""

from __future__ import annotations

import asyncio
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "tts" / "scripts"
sys.path.insert(0, str(SCRIPTS))

from tts_mcp_adapter import TTSAdapter  # noqa: E402
from tts_mcp_config import MCPConfig  # noqa: E402
from tts_mcp_http_log import (  # noqa: E402
    HeaderAuditMiddleware,
    HeaderTrafficStore,
    current_request_header,
)


class FakeProcess:
    returncode = 0

    async def communicate(self) -> tuple[bytes, bytes]:
        return b'{"status":"ok"}', b""


class MCPSessionContextTests(unittest.TestCase):
    def test_openai_session_is_scoped_to_the_current_subprocess(self) -> None:
        asyncio.run(self.contract())

    async def contract(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-mcp-session-") as temporary:
            captured: dict[str, str] = {}
            adapter = TTSAdapter(MCPConfig(ROOT / "tts"))

            async def app(_scope, _receive, send) -> None:
                self.assertEqual(current_request_header("X-OpenAI-Session"), "v1/chat-a")
                with patch(
                    "asyncio.create_subprocess_exec",
                    AsyncMock(return_value=FakeProcess()),
                ) as spawn:
                    await adapter._run(["status"])
                    captured.update(spawn.await_args.kwargs["env"])
                await send({"type": "http.response.start", "status": 200})
                await send({"type": "http.response.body", "body": b""})

            middleware = HeaderAuditMiddleware(
                app,
                HeaderTrafficStore(Path(temporary) / "headers.jsonl"),
            )
            await middleware(
                {
                    "type": "http",
                    "method": "POST",
                    "path": "/mcp",
                    "query_string": b"",
                    "headers": [(b"x-openai-session", b"v1/chat-a")],
                    "client": ("127.0.0.1", 1234),
                },
                AsyncMock(),
                AsyncMock(),
            )

            self.assertEqual(captured["TTS_SESSION_ID"], "v1/chat-a")
            self.assertEqual(captured["TTS_HARNESS"], "mcp")
            self.assertIsNone(current_request_header("x-openai-session"))


if __name__ == "__main__":
    unittest.main()

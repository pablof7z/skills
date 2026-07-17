#!/usr/bin/env python3
"""MCP discovery, stdio, annotations, and safe-view contracts."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "tts" / "scripts"
sys.path.insert(0, str(SCRIPTS))

from tts_mcp_config import MCPConfig
from tts_mcp_server import build_server
from tts_mcp_state import sanitize_item


EXPECTED_TOOLS = {
    "tts_archive_items",
    "tts_ask",
    "tts_generate",
    "tts_get_item",
    "tts_health",
    "tts_list_items",
    "tts_restore_items",
    "tts_speak",
    "tts_status",
    "tts_supersede_questions",
    "tts_wait_for_item",
}


class MCPInterfaceTests(unittest.TestCase):
    def test_discovery_exposes_complete_tool_and_resource_surface(self) -> None:
        server = build_server(MCPConfig(ROOT / "tts"))
        self.assertEqual(set(server._tool_manager._tools), EXPECTED_TOOLS)
        generate = server._tool_manager._tools["tts_generate"]
        self.assertFalse(generate.annotations.readOnlyHint)
        self.assertTrue(generate.annotations.openWorldHint)
        status = server._tool_manager._tools["tts_status"]
        self.assertTrue(status.annotations.readOnlyHint)
        self.assertEqual(
            set(str(uri) for uri in server._resource_manager._templates),
            {
                "tts://items/{item_id}",
                "tts://items/{item_id}/audio",
                "tts://items/{item_id}/attachments/{index}",
            },
        )

    def test_item_views_redact_host_paths_and_commands(self) -> None:
        value = sanitize_item({
            "id": "item-1",
            "status": "generated",
            "output_file": "/private/message.mp3",
            "asset_directory": "/private/assets",
            "retry_command": "/private/scripts/tts",
            "workspace": "/private/repository",
            "attachments": [{"label": "Context", "source_file": "/private/context.md"}],
        })
        serialized = json.dumps(value)
        self.assertNotIn("/private", serialized)
        self.assertEqual(value["audio_uri"], "tts://items/item-1/audio")
        self.assertEqual(
            value["attachments"][0]["resource_uri"],
            "tts://items/item-1/attachments/0",
        )

    def test_stdio_server_initializes_and_returns_health(self) -> None:
        asyncio.run(self._stdio_contract())

    async def _stdio_contract(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tts-mcp-stdio-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            environment = os.environ.copy()
            environment.update({
                "HOME": str(home),
                "TTS_STATE_DIR": str(root / "state"),
                "TTS_REMOTE_NO_MENU": "1",
            })
            parameters = StdioServerParameters(
                command=sys.executable,
                args=[str(SCRIPTS / "tts_mcp_server.py"), "--route", "local"],
                env=environment,
            )
            async with stdio_client(parameters) as streams:
                async with ClientSession(*streams) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    self.assertEqual({tool.name for tool in tools.tools}, EXPECTED_TOOLS)
                    health = await session.call_tool("tts_health", {})
                    self.assertFalse(health.isError)
                    self.assertEqual(health.structuredContent["status"], "ok")
                    self.assertEqual(health.structuredContent["route"], "local")


if __name__ == "__main__":
    unittest.main()

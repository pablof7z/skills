#!/usr/bin/env python3
"""Runtime configuration and path policy for the TTS MCP server."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Literal


RouteMode = Literal["automatic", "paired", "local"]


@dataclass(frozen=True)
class MCPConfig:
    skill_dir: Path
    route: RouteMode = "automatic"
    allowed_roots: tuple[Path, ...] = ()

    @property
    def tts_command(self) -> Path:
        return self.skill_dir / "scripts" / "tts"

    @property
    def menu_command(self) -> Path:
        return self.skill_dir / "scripts" / "tts-menu"

    def attachment_path(self, value: str) -> Path:
        path = Path(value).expanduser().resolve()
        if not path.is_file():
            raise ValueError(f"attachment does not exist: {value}")
        if not self.allowed_roots:
            raise ValueError("attachments require at least one configured --allow-root")
        if not any(path == root or root in path.parents for root in self.allowed_roots):
            raise ValueError("attachment is outside the configured allowed roots")
        return path

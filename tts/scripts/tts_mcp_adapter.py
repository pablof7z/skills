#!/usr/bin/env python3
"""Subprocess adapter from MCP tools to the durable TTS command surface."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Iterable

from tts_blossom import upload_mp3
from tts_mcp_config import MCPConfig
from tts_mcp_models import AttachmentInput, ItemFilters, QuestionBundleInput
from tts_mcp_state import sanitize_item, sanitize_value
from tts_remote_state import active_peer, ensure_backend


class TTSCommandError(RuntimeError):
    """A TTS command returned an error safe to surface to an MCP caller."""


class TTSAdapter:
    def __init__(self, config: MCPConfig) -> None:
        self.config = config

    async def speak(
        self,
        *,
        agent_name: str,
        subject: str,
        summary: str,
        message: str,
        attachments: list[AttachmentInput],
    ) -> dict[str, object]:
        paired = self.config.route == "paired"
        if paired and attachments:
            raise TTSCommandError("paired speech does not accept host-local attachment paths")
        command = self._speech_command(paired, agent_name, subject, summary, message)
        command.extend(self._attachment_arguments(attachments))
        result = await self._run(command, force_local=self.config.route == "local")
        return self._speech_result(result)

    async def ask(
        self,
        *,
        agent_name: str,
        subject: str,
        summary: str,
        message: str,
        bundle: QuestionBundleInput,
        wait_seconds: int,
        attachments: list[AttachmentInput],
    ) -> dict[str, object]:
        paired = self.config.route == "paired"
        normalized = self._question_bundle(bundle)
        if paired and (attachments or self._bundle_has_attachments(normalized)):
            raise TTSCommandError("paired questions do not accept host-local attachment paths")
        command = self._speech_command(paired, agent_name, subject, summary, message)
        command.extend(self._attachment_arguments(attachments))
        command.extend(["--ask", json.dumps(normalized, separators=(",", ":")), "--wait", f"{wait_seconds}s"])
        return sanitize_value(await self._run(command, timeout=wait_seconds + 300, force_local=self.config.route == "local"))

    async def generate(
        self,
        *,
        agent_name: str,
        subject: str,
        summary: str,
        message: str,
        wait_seconds: int,
    ) -> dict[str, object]:
        paired = self.config.route == "paired" or (
            self.config.route == "automatic" and active_peer() is not None
        )
        if paired:
            command = [
                "remote", "generate",
                "--agent-name", agent_name,
                "--subject", subject,
                "--summary", summary,
                "--message", message,
                "--wait", f"{wait_seconds}s",
            ]
            return sanitize_value(await self._run(command, timeout=wait_seconds + 60))
        generated = await self._run(
            [
                "--agent-name", agent_name,
                "--subject", subject,
                "--summary", summary,
                "--message", message,
                "--no-play",
            ],
            timeout=wait_seconds,
            force_local=True,
        )
        output_file = Path(str(generated.get("output_file") or ""))
        backend = await asyncio.to_thread(ensure_backend)
        descriptor = await asyncio.to_thread(upload_mp3, output_file, nsec=str(backend["nsec"]))
        return descriptor

    async def status(self) -> dict[str, object]:
        result = await self._run_menu(["status", "--json"])
        return sanitize_value(result)

    async def health(self) -> dict[str, object]:
        try:
            player = await self.status()
        except TTSCommandError as error:
            player = {"state": "unavailable", "error": str(error)}
        return {
            "status": "ok",
            "route": self.config.route,
            "paired_endpoint": active_peer() is not None,
            "local_endpoint_configured": bool(os.environ.get("KOKORO_API_ENDPOINT")),
            "blossom_server": os.environ.get("TTS_BLOSSOM_SERVER", "https://blossom.primal.net"),
            "player": player,
        }

    async def list_items(self, filters: ItemFilters) -> dict[str, object]:
        command = ["queue", "list", "--limit", str(filters.limit), "--offset", str(filters.offset)]
        if filters.agent_name:
            command.extend(["--agent-name", filters.agent_name])
        if filters.session_id:
            command.extend(["--session-id", filters.session_id])
        if filters.archived:
            command.append("--archived")
        if filters.include_archived:
            command.append("--all")
        result = await self._run_menu(command)
        result["items"] = [sanitize_item(item) for item in result.get("items", [])]
        return result

    async def get_item(self, item_id: str) -> dict[str, object]:
        return sanitize_item(await self._run_menu(["queue", "get", item_id]))

    async def wait_for_item(self, item_id: str, timeout_seconds: int) -> dict[str, object]:
        result = await self._run_menu(
            ["queue", "wait", item_id, "--timeout", f"{timeout_seconds}s"],
            timeout=timeout_seconds + 10,
        )
        return sanitize_value(result)

    async def archive(self, ids: list[str], reason: str, actor: str | None) -> dict[str, object]:
        command = ["queue", "archive", *ids, "--reason", reason]
        if actor:
            command.extend(["--actor", actor])
        return sanitize_value(await self._run_menu(command))

    async def restore(self, ids: list[str], reason: str, actor: str | None) -> dict[str, object]:
        command = ["queue", "restore", *ids, "--reason", reason]
        if actor:
            command.extend(["--actor", actor])
        return sanitize_value(await self._run_menu(command))

    async def supersede(
        self,
        ids: list[str],
        replacements: list[str],
        reason: str,
        actor: str | None,
    ) -> dict[str, object]:
        command = ["queue", "supersede", *ids]
        for replacement in replacements:
            command.extend(["--superseded-by", replacement])
        command.extend(["--reason", reason])
        if actor:
            command.extend(["--actor", actor])
        return sanitize_value(await self._run_menu(command))

    def _speech_command(
        self, paired: bool, agent: str, subject: str, summary: str, message: str,
    ) -> list[str]:
        prefix = ["remote", "speak"] if paired else []
        return [
            *prefix,
            "--agent-name", agent,
            "--subject", subject,
            "--summary", summary,
            "--message", message,
        ]

    def _attachment_arguments(self, attachments: Iterable[AttachmentInput]) -> list[str]:
        result: list[str] = []
        for attachment in attachments:
            path = self.config.attachment_path(attachment.path)
            result.extend(["--attach", attachment.label, str(path)])
        return result

    def _question_bundle(self, bundle: QuestionBundleInput) -> dict[str, object]:
        value = bundle.model_dump(exclude_none=True)
        for question in value["questions"]:
            self._normalize_attachment_rows(question.get("attachments", []))
            for suggestion in question.get("suggestions", []):
                self._normalize_attachment_rows(suggestion.get("attachments", []))
        return value

    def _normalize_attachment_rows(self, rows: list[dict[str, object]]) -> None:
        for row in rows:
            row["path"] = str(self.config.attachment_path(str(row["path"])))

    @staticmethod
    def _bundle_has_attachments(bundle: dict[str, object]) -> bool:
        return any(
            question.get("attachments")
            or any(option.get("attachments") for option in question.get("suggestions", []))
            for question in bundle["questions"]
        )

    def _speech_result(self, result: dict[str, object]) -> dict[str, object]:
        item_id = str(result.get("id") or "")
        cleaned = sanitize_value(result)
        if item_id:
            cleaned["item_uri"] = f"tts://items/{item_id}"
            cleaned["audio_uri"] = f"tts://items/{item_id}/audio"
        return cleaned

    async def _run_menu(self, arguments: list[str], timeout: int = 120) -> dict[str, object]:
        return await self._run(arguments, executable=self.config.menu_command, timeout=timeout)

    async def _run(
        self,
        arguments: list[str],
        *,
        executable: Path | None = None,
        timeout: int = 900,
        force_local: bool = False,
    ) -> dict[str, object]:
        environment = os.environ.copy()
        if force_local:
            environment["TTS_FORCE_LOCAL"] = "1"
        process = await asyncio.create_subprocess_exec(
            str(executable or self.config.tts_command),
            *arguments,
            env=environment,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=timeout)
        except (asyncio.CancelledError, TimeoutError):
            process.terminate()
            await process.communicate()
            raise TTSCommandError("TTS command was cancelled or timed out")
        if process.returncode != 0:
            raise TTSCommandError(self._safe_error(stderr.decode("utf-8", errors="replace")))
        try:
            value = json.loads(stdout.decode("utf-8"))
        except ValueError as error:
            raise TTSCommandError("TTS command returned invalid JSON") from error
        if not isinstance(value, dict):
            raise TTSCommandError("TTS command returned a non-object result")
        return value

    def _safe_error(self, value: str) -> str:
        message = " | ".join(line.strip() for line in value.splitlines() if line.strip())[-1000:]
        home = str(Path.home())
        return (message or "TTS command failed").replace(home, "<home>").replace(str(self.config.skill_dir), "<skill-dir>")

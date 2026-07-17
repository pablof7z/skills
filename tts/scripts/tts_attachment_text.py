#!/usr/bin/env python3
"""Narrated attachment text normalization and size limits."""

from __future__ import annotations

from pathlib import Path
import re


MAX_NARRATED_ATTACHMENT_WORDS = 2_000


class NarratedAttachmentLimitError(ValueError):
    """Raised when an attachment is too large to narrate safely."""


def markdown_for_speech(value: str) -> str:
    value = re.sub(r"```([^\n`]*)\n.*?```", _replace_lang_block_for_speech, value, flags=re.DOTALL)
    value = re.sub(r"!\[([^]]*)\]\([^)]+\)", r"\1", value)
    value = re.sub(r"\[([^]]+)\]\([^)]+\)", r"\1", value)
    value = re.sub(r"^\s{0,3}(?:#{1,6}|>|[-+*]|\d+[.)])\s+", "", value, flags=re.MULTILINE)
    value = re.sub(r"[`*_~]", "", value)
    return re.sub(r"\s+", " ", value).strip()


def narrated_attachment_speech(label: str, source: Path) -> str:
    speech = markdown_for_speech(source.read_text(encoding="utf-8"))
    if not speech:
        raise ValueError(f'Narrated attachment "{label}" did not contain narratable text.')
    count = len(speech.split())
    if count > MAX_NARRATED_ATTACHMENT_WORDS:
        raise NarratedAttachmentLimitError(
            f'Error: narrated attachment "{label}" contains {count} words; '
            f"the enforced limit is {MAX_NARRATED_ATTACHMENT_WORDS} words. "
            "Summarize it, split it into focused attachments, or attach the raw artifact "
            "with a non-text extension so it is not narrated."
        )
    return speech


def _replace_lang_block_for_speech(match: re.Match[str]) -> str:
    fence = match.group(1).strip()
    if not fence:
        return match.group(0)
    return " "

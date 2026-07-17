#!/usr/bin/env python3
"""Narrated attachment text normalization and size limits."""

from __future__ import annotations

from pathlib import Path

try:
    from .tts_speech_text import markdown_for_speech
except ImportError:
    from tts_speech_text import markdown_for_speech


MAX_NARRATED_ATTACHMENT_WORDS = 2_000


class NarratedAttachmentLimitError(ValueError):
    """Raised when an attachment is too large to narrate safely."""

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

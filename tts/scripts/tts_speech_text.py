#!/usr/bin/env python3
"""Convert displayed Markdown into text intended for speech synthesis."""

from __future__ import annotations

import re
import sys


_FENCED_BLOCK = re.compile(r"```([^\n`]*)\n(.*?)```", re.DOTALL)
_TERMINAL_PAUSE = re.compile(r"[.!?…:;][\]\)}'\"”’]*$")


def markdown_for_speech(value: str) -> str:
    """Remove visual Markdown while preserving audible block boundaries."""
    value = value.replace("\r\n", "\n").replace("\r", "\n")
    value = _FENCED_BLOCK.sub(_replace_fenced_block, value)
    value = re.sub(
        r"(?m)^([^\n]+)\n[ \t]{0,3}(?:={2,}|-{2,})[ \t]*$",
        lambda match: f"\n\n{match.group(1).strip()}\n\n",
        value,
    )
    value = re.sub(
        r"(?m)^[ \t]{0,3}#{1,6}[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$",
        lambda match: f"\n\n{match.group(1).strip()}\n\n",
        value,
    )
    value = re.sub(r"(?m)^[ \t]{0,3}(?:[*_-][ \t]*){3,}$", "\n\n", value)
    value = re.sub(
        r"(?m)^[ \t]{0,3}(?:[-+*]|\d+[.)])[ \t]+(.+)$",
        lambda match: f"\n\n{match.group(1).strip()}\n\n",
        value,
    )
    value = re.sub(r"(?m)^[ \t]{0,3}>[ \t]?", "\n\n", value)
    value = re.sub(
        r'(?m)^\s*\["(.*)"\]\s*$',
        lambda match: f"\n\n{match.group(1).strip()}\n\n",
        value,
    )
    value = re.sub(r"!\[([^]]*)\]\([^)]+\)", r"\1", value)
    value = re.sub(r"\[([^]]+)\]\([^)]+\)", r"\1", value)
    value = re.sub(r"[`*_~]", "", value)

    blocks = []
    for raw_block in re.split(r"\n\s*\n+", value):
        block = re.sub(r"\s+", " ", raw_block).strip()
        if not block:
            continue
        blocks.append(_with_terminal_pause(block))
    return "\n\n".join(blocks)


def _replace_fenced_block(match: re.Match[str]) -> str:
    language = match.group(1).strip()
    body = match.group(2).strip()
    return "\n\n" if language else f"\n\n{body}\n\n"


def _with_terminal_pause(value: str) -> str:
    return value if _TERMINAL_PAUSE.search(value) else value + "."


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: tts_speech_text.py <markdown>")
    sys.stdout.write(markdown_for_speech(sys.argv[1]))

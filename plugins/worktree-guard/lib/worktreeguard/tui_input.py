"""Raw terminal key decoding shared by WorktreeGuard's configuration UI."""

from __future__ import annotations

import os
import select


_CSI_ARROWS = {
    b"A": "up", b"B": "down", b"C": "right", b"D": "left", b"H": "home", b"F": "end",
}
_SS3_ARROWS = {b"A": "up", b"B": "down", b"C": "right", b"D": "left"}


def read_key(fd: int) -> str | None:
    """Read one key without changing printable characters' case or content."""
    ch = os.read(fd, 1)
    if ch == b"":
        raise EOFError
    if ch == b"\x1b":
        if not select.select([fd], [], [], 0.1)[0]:
            return "esc"
        nxt = os.read(fd, 1)
        if nxt in (b"[", b"O"):
            return _csi_key(fd, nxt)
        return "esc"
    if ch in (b"\r", b"\n"):
        return "enter"
    if ch == b"\x03":
        raise KeyboardInterrupt
    if ch in (b"\x7f", b"\x08"):
        return "backspace"
    if ch == b"\x15":
        return "ctrl-u"
    if ch == b"\x0e":
        return "ctrl-n"
    return _decode_character(fd, ch)


def drain(fd: int) -> None:
    """Discard input bytes that were queued before the UI appeared."""
    while select.select([fd], [], [], 0)[0]:
        if not os.read(fd, 4096):
            break


def _decode_character(fd: int, first: bytes) -> str:
    if first[0] < 0x80:
        return first.decode("utf-8")
    size = _utf8_size(first[0])
    encoded = bytearray(first)
    while len(encoded) < size and select.select([fd], [], [], 0.1)[0]:
        chunk = os.read(fd, size - len(encoded))
        if not chunk:
            break
        encoded.extend(chunk)
    return bytes(encoded).decode("utf-8", "replace")


def _utf8_size(byte: int) -> int:
    if byte & 0b1111_1000 == 0b1111_0000:
        return 4
    if byte & 0b1111_0000 == 0b1110_0000:
        return 3
    if byte & 0b1110_0000 == 0b1100_0000:
        return 2
    return 1


def _csi_key(fd: int, intro: bytes) -> str | None:
    while True:
        if not select.select([fd], [], [], 0.1)[0]:
            return None
        byte = os.read(fd, 1)
        if byte == b"":
            return None
        if 0x40 <= byte[0] <= 0x7E:
            return (_CSI_ARROWS if intro == b"[" else _SS3_ARROWS).get(byte)

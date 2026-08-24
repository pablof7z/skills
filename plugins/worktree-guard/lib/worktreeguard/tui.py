"""Inquirer-style interactive configuration UI for ``.wtg.json`` (stdlib only)."""

from __future__ import annotations

import os
import select
import sys
from pathlib import Path
from typing import Any, Callable

from .storage import VALID_WRITE_MODES, config_path, read_config, write_config


RESET = "\x1b[0m"
BOLD = "\x1b[1m"
DIM = "\x1b[2m"
CYAN = "\x1b[36m"
GREEN = "\x1b[32m"
YELLOW = "\x1b[33m"
RED = "\x1b[90m"
HIDE_CURSOR = "\x1b[?25l"
SHOW_CURSOR = "\x1b[?25h"
CLEAR = "\x1b[H\x1b[2J"

WriteFn = Callable[[str], Any]
KeyFn = Callable[[], str]

_WRITE_OPTIONS = [
    ("block", "deny native edits until a session grant"),
    ("off", "allow native edits silently"),
    ("warn", "allow edits but warn on every one"),
]
_BRANCH_OPTIONS = [
    ("follow", "branch changes behave like other blocked commands"),
    ("manual", "always require a manual human approval"),
    ("block", "always deny branch changes; never grantable"),
]


def is_interactive() -> bool:
    return sys.stdin.isatty() and sys.stdout.isatty()


def run_interactive_config(base_path: Path) -> int:
    import termios
    import tty

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    data = read_config(base_path)
    path = config_path(base_path)
    try:
        tty.setcbreak(fd)
        _drain(fd)
        return _config_loop(base_path, path, data, lambda: _read_key(fd), sys.stdout.write)
    except (KeyboardInterrupt, EOFError):
        sys.stdout.write(CLEAR)
        sys.stdout.write(f"{DIM}Cancelled.{RESET}\n")
        sys.stdout.flush()
        return 0
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write(SHOW_CURSOR + RESET)
        sys.stdout.flush()


def _config_loop(
    base_path: Path, path: Path, data: dict[str, Any], read_key: KeyFn, write: WriteFn,
) -> int:
    items = ["enabled", "writes", "branchChanges", "allowBypass", "save", "cancel"]
    index = 0
    dirty = False
    while True:
        write(_main_screen(base_path, path, data, items, index, dirty))
        key = read_key()
        if key is None:
            continue
        if key in ("up", "k"):
            index = (index - 1) % len(items)
        elif key in ("down", "j", "tab"):
            index = (index + 1) % len(items)
        elif key in ("enter", "right"):
            item = items[index]
            if item in ("enabled", "allowBypass"):
                data[item] = not data[item]
                dirty = True
            elif item == "writes":
                choice = _writes_picker(data["writes"], read_key, write)
                if choice is not None and choice != data["writes"]:
                    data["writes"] = choice
                    dirty = True
            elif item == "branchChanges":
                choice = _branch_picker(data["branchChanges"], read_key, write)
                if choice is not None and choice != data["branchChanges"]:
                    data["branchChanges"] = choice
                    dirty = True
            elif item == "save":
                return _save(base_path, path, data, write)
            elif item == "cancel":
                return _cancel(path, dirty, write)
        elif key == "s":
            return _save(base_path, path, data, write)
        elif key in ("q", "esc"):
            return _cancel(path, dirty, write)


def _writes_picker(current: str, read_key: KeyFn, write: WriteFn) -> str | None:
    index = next((i for i, (value, _) in enumerate(_WRITE_OPTIONS) if value == current), 0)
    while True:
        write(_writes_screen(index))
        key = read_key()
        if key is None:
            continue
        if key in ("up", "k"):
            index = (index - 1) % len(_WRITE_OPTIONS)
        elif key in ("down", "j", "tab"):
            index = (index + 1) % len(_WRITE_OPTIONS)
        elif key in ("enter", "right"):
            return _WRITE_OPTIONS[index][0]
        elif key in ("esc", "q", "left", "backspace"):
            return None


def _branch_picker(current: str, read_key: KeyFn, write: WriteFn) -> str | None:
    index = next((i for i, (value, _) in enumerate(_BRANCH_OPTIONS) if value == current), 0)
    while True:
        write(_branch_screen(index))
        key = read_key()
        if key is None:
            continue
        if key in ("up", "k"):
            index = (index - 1) % len(_BRANCH_OPTIONS)
        elif key in ("down", "j", "tab"):
            index = (index + 1) % len(_BRANCH_OPTIONS)
        elif key in ("enter", "right"):
            return _BRANCH_OPTIONS[index][0]
        elif key in ("esc", "q", "left", "backspace"):
            return None


def _save(base_path: Path, path: Path, data: dict[str, Any], write: WriteFn) -> int:
    write_config(base_path, data)
    write(CLEAR + f"{GREEN}{BOLD}✓{RESET} Saved {path}\n\n")
    return 0


def _cancel(path: Path, dirty: bool, write: WriteFn) -> int:
    write(CLEAR)
    if dirty:
        write(f"{YELLOW}Discarded changes{RESET} ({path} unchanged)\n")
    else:
        write(f"{DIM}No changes.{RESET}\n")
    return 0


def _main_screen(
    base_path: Path, path: Path, data: dict[str, Any], items: list[str], index: int, dirty: bool,
) -> str:
    out = [CLEAR, HIDE_CURSOR, f"{BOLD} WorktreeGuard configuration{RESET}\n"]
    out.append(f"{DIM} repo:{RESET} {base_path}\n")
    status = "present" if path.exists() else f"{DIM}not present (defaults){RESET}"
    out.append(f"{DIM} file:{RESET} {path} ({status})\n\n")
    for i, item in enumerate(items):
        out.append(_main_row(item, data, i == index))
    mark = f"  {YELLOW}● unsaved{RESET}" if dirty else ""
    out.append(f"\n {DIM}↑/↓ navigate · enter edit · s save · q cancel{RESET}{mark}\n")
    return "".join(out)


def _main_row(item: str, data: dict[str, Any], focused: bool) -> str:
    pointer = f"{CYAN}{BOLD}❯{RESET} " if focused else "  "
    name = f"{BOLD}{item}{RESET}" if focused else item
    if item in ("enabled", "allowBypass"):
        return f" {pointer}{name:<13} {_bool_label(data[item])}\n"
    if item == "writes":
        return f" {pointer}{name:<13} {_writes_label(data['writes'])}\n"
    if item == "branchChanges":
        return f" {pointer}{name:<13} {_branch_label(data['branchChanges'])}\n"
    if item == "save":
        label = f"{GREEN}Save and write .wtg.json{RESET}" if focused else "Save and write .wtg.json"
        return f"\n {pointer}{label}\n"
    label = f"{RED}Cancel{RESET} (discard changes)" if focused else "Cancel (discard changes)"
    return f" {pointer}{label}\n"


def _writes_screen(index: int) -> str:
    out = [CLEAR, HIDE_CURSOR, f"{BOLD} writes{RESET}\n\n"]
    for i, (value, desc) in enumerate(_WRITE_OPTIONS):
        pointer = f"{CYAN}{BOLD}❯{RESET} " if i == index else "  "
        out.append(f" {pointer}{_writes_label(value):<10} {DIM}{desc}{RESET}\n")
    out.append(f"\n {DIM}↑/↓ choose · enter confirm · esc back{RESET}\n")
    return "".join(out)


def _bool_label(value: bool) -> str:
    return f"{GREEN}true{RESET}" if value else f"{DIM}false{RESET}"


def _writes_label(value: str) -> str:
    if value == "block":
        return f"{RED}block{RESET}"
    if value == "off":
        return f"{DIM}off{RESET}"
    if value == "warn":
        return f"{YELLOW}warn{RESET}"
    return value


def _branch_screen(index: int) -> str:
    out = [CLEAR, HIDE_CURSOR, f"{BOLD} branchChanges{RESET}\n\n"]
    for i, (value, desc) in enumerate(_BRANCH_OPTIONS):
        pointer = f"{CYAN}{BOLD}❯{RESET} " if i == index else "  "
        out.append(f" {pointer}{_branch_label(value):<10} {DIM}{desc}{RESET}\n")
    out.append(f"\n {DIM}↑/↓ choose · enter confirm · esc back{RESET}\n")
    return "".join(out)


def _branch_label(value: str) -> str:
    if value == "follow":
        return f"{GREEN}follow{RESET}"
    if value == "manual":
        return f"{YELLOW}manual{RESET}"
    if value == "block":
        return f"{RED}block{RESET}"
    return value


def _read_key(fd: int) -> str | None:
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
    return ch.decode("utf-8", "replace").lower()


_CSI_ARROWS = {b"A": "up", b"B": "down", b"C": "right", b"D": "left", b"H": "home", b"F": "end"}
_SS3_ARROWS = {b"A": "up", b"B": "down", b"C": "right", b"D": "left"}


def _csi_key(fd: int, intro: bytes) -> str | None:
    """Parse a CSI (``\x1b[``) or SS3 (``\x1bO``) sequence.

    Unknown sequences (focus events, mouse reports, etc.) return ``None`` so the
    UI ignores them instead of bailing out as if the user pressed Escape.
    """
    while True:
        if not select.select([fd], [], [], 0.1)[0]:
            return None
        b = os.read(fd, 1)
        if b == b"":
            return None
        if 0x40 <= b[0] <= 0x7E:
            if intro == b"[":
                return _CSI_ARROWS.get(b)
            return _SS3_ARROWS.get(b)


def _drain(fd: int) -> None:
    """Discard any input bytes already waiting before the UI starts."""
    while select.select([fd], [], [], 0)[0]:
        if not os.read(fd, 4096):
            break
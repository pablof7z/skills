"""Inquirer-style interactive configuration UI for \`\`.wtg.json\`\` (stdlib only)."""

from __future__ import annotations

import os
import select
import sys
from pathlib import Path
from typing import Any, Callable

from .core import GUARD_GROUPS
from .storage import config_path, read_config, write_config


RESET = "\x1b[0m"
BOLD = "\x1b[1m"
DIM = "\x1b[2m"
CYAN = "\x1b[36m"
GREEN = "\x1b[32m"
YELLOW = "\x1b[33m"
RED = "\x1b[31m"
UNDERLINE = "\x1b[4m"
HIDE_CURSOR = "\x1b[?25l"
SHOW_CURSOR = "\x1b[?25h"
CLEAR = "\x1b[H\x1b[2J"

WriteFn = Callable[[str], Any]
KeyFn = Callable[[], str]

_GROUP_LABELS = {
    "writes": "file writes",
    "branchChanges": "changing branch",
    "discard": "discard",
    "stash": "stash",
}
_GROUP_DESCRIPTIONS = {
    "writes": "Edit/Write/MultiEdit/NotebookEdit/apply_patch",
    "branchChanges": "git switch, git checkout <ref>/-b/-B",
    "discard": "git clean/reset/restore/rebase, path-restore",
    "stash": "git stash \u2014 can disturb agent's uncommitted work",
}
_ENABLED_DESCRIPTION = "master switch \u2014 false disables every guard group"

_DISPOSITION_CYCLE = ["block", "warn", "allow"]
_BYPASS_CYCLE = ["auto", "manual", "none"]

_LABEL_WIDTH = 17


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


def _build_items(data: dict[str, Any]) -> list[str]:
    if data.get("enabled", True):
        return ["enabled", *GUARD_GROUPS, "save", "cancel"]
    return ["enabled", "save", "cancel"]


def _config_loop(
    base_path: Path, path: Path, data: dict[str, Any], read_key: KeyFn, write: WriteFn,
) -> int:
    items = _build_items(data)
    index = 0
    dirty = False
    sel = 0  # 0 = mode selector active, 1 = approval selector active

    while True:
        write(_main_screen(base_path, path, data, items, index, dirty, sel))
        key = read_key()
        if key is None:
            continue

        item = items[index]

        if key in ("up", "k"):
            index = (index - 1) % len(items)
            sel = 0
        elif key in ("down", "j"):
            index = (index + 1) % len(items)
            sel = 0
        elif key == "tab":
            if item in GUARD_GROUPS:
                if sel == 0 and data[item]["disposition"] == "block":
                    sel = 1
                else:
                    index = (index + 1) % len(items)
                    sel = 0
            else:
                index = (index + 1) % len(items)
                sel = 0
        elif key == "right":
            if item in GUARD_GROUPS:
                if sel == 0 and data[item]["disposition"] == "block":
                    sel = 1
        elif key == "left":
            if item in GUARD_GROUPS and sel == 1:
                sel = 0
        elif key == "enter":
            if item == "enabled":
                data[item] = not data[item]
                dirty = True
                items = _build_items(data)
                index = min(index, len(items) - 1)
                sel = 0
            elif item in GUARD_GROUPS:
                if sel == 0:
                    cur = data[item]["disposition"]
                    nxt = _DISPOSITION_CYCLE[(_DISPOSITION_CYCLE.index(cur) + 1) % len(_DISPOSITION_CYCLE)]
                    data[item]["disposition"] = nxt
                    dirty = True
                    if nxt != "block":
                        sel = 0
                elif sel == 1:
                    cur = data[item]["bypass"]
                    nxt = _BYPASS_CYCLE[(_BYPASS_CYCLE.index(cur) + 1) % len(_BYPASS_CYCLE)]
                    data[item]["bypass"] = nxt
                    dirty = True
            elif item == "save":
                return _save(base_path, path, data, write)
            elif item == "cancel":
                return _cancel(path, dirty, write)
        elif key == "s":
            return _save(base_path, path, data, write)
        elif key in ("q", "esc"):
            return _cancel(path, dirty, write)


def _save(base_path: Path, path: Path, data: dict[str, Any], write: WriteFn) -> int:
    write_config(base_path, data)
    write(CLEAR + f"{GREEN}{BOLD}\u2713{RESET} Saved {path}\n\n")
    return 0


def _cancel(path: Path, dirty: bool, write: WriteFn) -> int:
    write(CLEAR)
    if dirty:
        write(f"{YELLOW}Discarded changes{RESET} ({path} unchanged)\n")
    else:
        write(f"{DIM}No changes.{RESET}\n")
    return 0


def _main_screen(
    base_path: Path, path: Path, data: dict[str, Any], items: list[str],
    index: int, dirty: bool, sel: int,
) -> str:
    out = [CLEAR, HIDE_CURSOR, f"{BOLD} WorktreeGuard configuration{RESET}\n"]
    out.append(f"{DIM} repo:{RESET} {base_path}\n")
    status = "present" if path.exists() else f"{DIM}not present (defaults){RESET}"
    out.append(f"{DIM} file:{RESET} {path} ({status})\n\n")
    for i, item in enumerate(items):
        focused = (i == index)
        out.append(_main_row(item, data, focused, sel if focused else 0))
    mark = f"  {YELLOW}\u25cf unsaved{RESET}" if dirty else ""
    hint = f"\n {DIM}{_hint_text(items[index], sel, data)}{RESET}{mark}\n"
    out.append(hint)
    return "".join(out)



def _hint_text(item: str, sel: int, data: dict[str, Any]) -> str:
    if item == "enabled":
        return "\u2191/\u2193 navigate \u00b7 enter toggle \u00b7 s save \u00b7 q quit"
    if item in GUARD_GROUPS:
        if sel == 1:
            return "\u2191/\u2193 navigate \u00b7 enter cycle \u00b7 \u2190 back \u00b7 s save \u00b7 q quit"
        if data[item]["disposition"] == "block":
            return "\u2191/\u2193 navigate \u00b7 enter cycle \u00b7 tab approval \u00b7 s save \u00b7 q quit"
        return "\u2191/\u2193 navigate \u00b7 enter cycle \u00b7 s save \u00b7 q quit"
    return "\u2191/\u2193 navigate \u00b7 enter select \u00b7 s save \u00b7 q quit"

def _main_row(item: str, data: dict[str, Any], focused: bool, sel: int) -> str:
    pointer = f"{CYAN}{BOLD}\u276f{RESET} " if focused else "  "

    if item == "enabled":
        name = f"{BOLD}enabled{RESET}" if focused else "enabled"
        value = _bool_label(data[item])
        pad = " " * max(1, _LABEL_WIDTH - len("enabled"))
        return f" {pointer}{name}{pad} {value}  {DIM}{_ENABLED_DESCRIPTION}{RESET}\n"

    if item in GUARD_GROUPS:
        return _group_row(pointer, item, data[item], focused, sel)

    if item == "save":
        label = f"{GREEN}Save and write .wtg.json{RESET}" if focused else "Save and write .wtg.json"
        return f"\n {pointer}{label}\n"
    label = f"{RED}Cancel{RESET} (discard changes)" if focused else "Cancel (discard changes)"
    return f" {pointer}{label}\n"


def _group_row(pointer: str, group: str, policy: dict[str, str], focused: bool, sel: int) -> str:
    label = _GROUP_LABELS.get(group, group)
    desc = _GROUP_DESCRIPTIONS.get(group, "")
    disp = policy["disposition"]
    byp = policy["bypass"]

    label_styled = f"{BOLD}{label}{RESET}" if focused else label
    label_pad = " " * max(1, _LABEL_WIDTH - len(label))

    if focused:
        if sel == 0:
            mode_s = _disposition_label(disp, active=True)
            mode_p = disp
            if disp == "block":
                bp_s = f"  {_bypass_phrase_colored(byp)}"
                bp_p = f"  {_bypass_phrase(byp)}"
            else:
                bp_s = bp_p = ""
            styled_val = mode_s + bp_s
            plain_val = mode_p + bp_p
        else:
            styled_val = f"{_disposition_label(disp)}  {_bypass_phrase_colored(byp, active=True)}"
            plain_val = f"{disp}  {_bypass_phrase(byp)}"
    else:
        if disp == "block":
            styled_val = f"{_disposition_label(disp)}, {_bypass_phrase_colored(byp)}"
            plain_val = f"{disp}, {_bypass_phrase(byp)}"
        else:
            styled_val = _disposition_label(disp)
            plain_val = disp

    pad = " " * max(2, 32 - len(plain_val))
    return f" {pointer}{label_styled}{label_pad}{styled_val}{pad}{DIM}{desc}{RESET}\n"


def _bool_label(value: bool) -> str:
    return f"{GREEN}true{RESET}" if value else f"{DIM}false{RESET}"


def _disposition_label(value: str, active: bool = False) -> str:
    ul = UNDERLINE if active else ""
    if value == "block":
        return f"{RED}{ul}block{RESET}"
    if value == "warn":
        return f"{YELLOW}{ul}warn{RESET}"
    if value == "allow":
        return f"{GREEN}{ul}allow{RESET}"
    return value


def _bypass_phrase(byp: str) -> str:
    if byp == "auto":
        return "auto-approve"
    if byp == "manual":
        return "require human approval"
    if byp == "none":
        return "never allowed"
    return byp


def _bypass_phrase_colored(byp: str, active: bool = False) -> str:
    ul = UNDERLINE if active else ""
    if byp == "auto":
        return f"{GREEN}{ul}auto-approve{RESET}"
    if byp == "manual":
        return f"{YELLOW}{ul}require human approval{RESET}"
    if byp == "none":
        return f"{RED}{ul}never allowed{RESET}"
    return byp


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
    """Parse a CSI (\`\x1b[\`) or SS3 (\`\x1bO\`) sequence.

    Unknown sequences return None so the UI ignores them.
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

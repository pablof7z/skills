"""The focused text editor used by WorktreeGuard's configuration UI."""

from __future__ import annotations

from typing import Any, Callable


RESET = "\x1b[0m"
BOLD = "\x1b[1m"
DIM = "\x1b[2m"
CYAN = "\x1b[36m"
HIDE_CURSOR = "\x1b[?25l"
CLEAR = "\x1b[H\x1b[2J"

KeyFn = Callable[[], str | None]
WriteFn = Callable[[str], Any]


def edit_policy_message(
    label: str, current: str | None, read_key: KeyFn, write: WriteFn,
) -> str | None:
    """Edit an optional policy message; Escape restores ``current`` unchanged."""
    value = current or ""
    while True:
        write(_screen(label, value))
        key = read_key()
        if key is None:
            continue
        if key == "enter":
            return value if value.strip() else None
        if key == "esc":
            return current
        if key == "backspace":
            value = value[:-1]
        elif key == "ctrl-u":
            value = ""
        elif key == "ctrl-n":
            value += "\n"
        elif len(key) == 1 and key.isprintable():
            value += key


def _screen(label: str, value: str) -> str:
    contents = value or f"{DIM}(default WorktreeGuard message){RESET}"
    return (
        f"{CLEAR}{HIDE_CURSOR}{BOLD} Custom message: {label}{RESET}\n\n"
        " This text completely replaces WorktreeGuard's agent-facing message.\n\n"
        f" {CYAN}{contents}{RESET}\n\n"
        f" {DIM}type to edit · enter done · esc cancel · ctrl-u clear · ctrl-n line break{RESET}\n"
    )

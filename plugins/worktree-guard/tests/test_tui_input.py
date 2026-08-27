"""Tests for raw terminal key decoding used by the configuration message editor."""

from __future__ import annotations

import os
import sys
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "lib"))

from worktreeguard.tui_input import read_key  # noqa: E402


class RawKeyTests(unittest.TestCase):
    def read(self, encoded: bytes) -> str | None:
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, encoded)
            return read_key(read_fd)
        finally:
            os.close(read_fd)
            os.close(write_fd)

    def test_printable_key_preserves_case(self) -> None:
        self.assertEqual(self.read(b"A"), "A")

    def test_utf8_key_is_one_character(self) -> None:
        self.assertEqual(self.read("Δ".encode("utf-8")), "Δ")

    def test_message_editor_control_keys_are_named(self) -> None:
        self.assertEqual(self.read(b"\x15"), "ctrl-u")
        self.assertEqual(self.read(b"\x0e"), "ctrl-n")

    def test_arrow_key_remains_a_navigation_action(self) -> None:
        self.assertEqual(self.read(b"\x1b[A"), "up")


if __name__ == "__main__":
    unittest.main()

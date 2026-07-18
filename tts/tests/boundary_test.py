#!/usr/bin/env python3
"""Mechanical ownership checks for the installed producer adapter."""

from __future__ import annotations

import ast
from pathlib import Path
import unittest


class AdapterBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.skill = Path(__file__).resolve().parents[1]

    def test_skill_contains_no_product_runtime(self) -> None:
        self.assertFalse((self.skill / "macos").exists())
        self.assertFalse((self.skill / "mcp").exists())
        scripts = {
            path.name
            for path in (self.skill / "scripts").iterdir()
            if path.is_file() and path.name != ".DS_Store"
        }
        self.assertEqual(scripts, {"tts", "tts29_request.py"})

    def test_runtime_imports_only_local_shaping_and_process_tools(self) -> None:
        allowed = {
            "argparse",
            "hashlib",
            "json",
            "os",
            "pathlib",
            "re",
            "subprocess",
            "sys",
            "tts29_request",
            "typing",
            "__future__",
        }
        imported = set()
        for path in (self.skill / "scripts").iterdir():
            if not path.is_file():
                continue
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    imported.update(alias.name.split(".")[0] for alias in node.names)
                elif isinstance(node, ast.ImportFrom) and node.module:
                    imported.add(node.module.split(".")[0])
        self.assertEqual(imported - allowed, set())


if __name__ == "__main__":
    unittest.main()

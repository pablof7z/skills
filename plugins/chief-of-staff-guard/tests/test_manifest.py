"""Tests that the plugin manifests wire up the hook matcher correctly."""

from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ManifestTests(unittest.TestCase):
    def test_pre_tool_use_matcher_covers_shell_and_native_write_tools(self) -> None:
        hooks = json.loads((ROOT / "hooks/hooks.json").read_text(encoding="utf-8"))["hooks"]
        self.assertEqual(set(hooks), {"PreToolUse"})
        matcher = "Bash|Shell|apply_patch|Edit|Write|MultiEdit|NotebookEdit"
        self.assertEqual(hooks["PreToolUse"][0].get("matcher"), matcher)

    def test_claude_plugin_manifest_is_valid(self) -> None:
        manifest = json.loads((ROOT / ".claude-plugin/plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["name"], "chief-of-staff-guard")

    def test_codex_plugin_manifest_is_valid(self) -> None:
        manifest = json.loads((ROOT / ".codex-plugin/plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["name"], "chief-of-staff-guard")


if __name__ == "__main__":
    unittest.main()

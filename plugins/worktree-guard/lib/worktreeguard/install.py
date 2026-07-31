"""Install stable hook shims and Grok global hook registration."""

from __future__ import annotations

import json
import os
import shutil
import stat
from pathlib import Path

HOOK_MATCHER = (
    "Bash|Shell|run_terminal_command|run_terminal_cmd|apply_patch|"
    "Edit|Write|MultiEdit|NotebookEdit|search_replace"
)
SHIMS = ("codex", "claude", "grok", "dispatch")


def plugin_root() -> Path:
    override = os.environ.get("WTG_PLUGIN_ROOT")
    if override:
        return Path(override).expanduser().resolve()
    # bin/wtg -> plugin root
    return Path(__file__).resolve().parents[2]


def install_hooks(*, grok: bool = True) -> list[str]:
    """Install stable shims and optionally register a Grok global hook.

    Grok 0.2.x discovers plugin hooks but does not execute them. Global hooks
    under ``~/.grok/hooks/`` do run, so WorktreeGuard registers there with an
    absolute path to the dispatch shim. Claude/Codex continue to use their
    plugin hook manifests.
    """
    root = plugin_root()
    messages: list[str] = []
    bin_dir = Path.home() / ".local" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    for name in SHIMS:
        source = root / "bin" / f"wtg-hook-{name}"
        if not source.is_file():
            messages.append(f"missing source shim: {source}")
            continue
        target = bin_dir / f"wtg-hook-{name}"
        shutil.copy2(source, target)
        target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        messages.append(f"installed {target}")

    wtg_source = root / "bin" / "wtg"
    if wtg_source.is_file():
        wtg_target = bin_dir / "wtg"
        shutil.copy2(wtg_source, wtg_target)
        # Ensure the copied CLI can import the package from the plugin root.
        wtg_target.write_text(
            "#!/usr/bin/env python3\n"
            "from __future__ import annotations\n"
            "import sys\n"
            f"sys.path.insert(0, {str(root / 'lib')!r})\n"
            "from worktreeguard import main\n"
            "raise SystemExit(main())\n",
            encoding="utf-8",
        )
        wtg_target.chmod(wtg_target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        messages.append(f"installed {wtg_target}")

    if grok:
        messages.extend(install_grok_global_hook(bin_dir / "wtg-hook-dispatch"))
    return messages


def install_grok_global_hook(dispatch: Path) -> list[str]:
    hooks_dir = Path.home() / ".grok" / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    path = hooks_dir / "worktree-guard.json"
    payload = {
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": HOOK_MATCHER,
                    "hooks": [
                        {
                            "type": "command",
                            "command": f"{dispatch} pre-tool-use",
                            "timeout": 5,
                            "statusMessage": "Checking base-checkout mutation",
                        }
                    ],
                }
            ]
        }
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return [f"registered Grok global hook {path}"]

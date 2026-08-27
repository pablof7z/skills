"""Install stable hook shims and Grok global hook registration."""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
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
        install_executable(source, target)
        messages.append(f"installed {target}")

    wtg_source = root / "bin" / "wtg"
    if wtg_source.is_file():
        wtg_target = bin_dir / "wtg"
        # Always write a real file that imports this plugin root; never write
        # through an existing symlink (e.g. old Claude marketplace pin).
        replace_path(wtg_target)
        wtg_target.write_text(
            "#!/usr/bin/env python3\n"
            "from __future__ import annotations\n"
            "import sys\n"
            f"sys.path.insert(0, {str(root / 'lib')!r})\n"
            "from worktreeguard import main\n"
            "raise SystemExit(main())\n",
            encoding="utf-8",
        )
        make_executable(wtg_target)
        messages.append(f"installed {wtg_target}")

    if grok:
        messages.extend(install_grok_global_hook(bin_dir / "wtg-hook-dispatch"))
    messages.extend(install_toast(root, bin_dir))
    return messages


def toast_binary_path() -> Path:
    return Path.home() / ".local" / "bin" / "wtg-toast"


def install_toast(root: Path, bin_dir: Path) -> list[str]:
    """Compile the native notification/approval toast, if this machine can.

    macOS-only, and only when the Swift toolchain is present. Its absence just
    means notifications.py falls back to a plain approval prompt — never a
    reason to fail the rest of install-hooks.
    """
    script = root / "bin" / "wtg-focus-iterm.applescript"
    if script.is_file():
        shutil.copy2(script, bin_dir / "wtg-focus-iterm.applescript")

    if sys.platform != "darwin":
        return ["skipped wtg-toast (not macOS)"]
    swiftc = shutil.which("swiftc")
    if not swiftc:
        return ["skipped wtg-toast (no swiftc on PATH)"]
    source = root / "bin" / "wtg-toast.swift"
    if not source.is_file():
        return [f"missing source: {source}"]
    target = toast_binary_path()
    result = subprocess.run(
        [swiftc, "-O", str(source), "-o", str(target)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        return [f"failed to build wtg-toast: {result.stderr.strip()[-500:]}"]
    return [f"installed {target}"]


def install_executable(source: Path, target: Path) -> None:
    replace_path(target)
    shutil.copy2(source, target)
    make_executable(target)


def replace_path(path: Path) -> None:
    if path.is_symlink() or path.exists():
        path.unlink()


def make_executable(path: Path) -> None:
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


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

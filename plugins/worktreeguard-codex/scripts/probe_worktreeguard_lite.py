#!/usr/bin/env python3
"""Hook-level regression probe for WorktreeGuard-lite."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WTG = ROOT / "bin" / "wtg"


def main() -> int:
    temp = Path(tempfile.mkdtemp(prefix="wtg-probe-")).resolve()
    try:
        env = os.environ.copy()
        env["WTG_STATE_FILE"] = str(temp / "state.json")
        env["WTG_ACTION_LOG_FILE"] = str(temp / "actions.jsonl")
        env["WTG_DENY_LOG_FILE"] = str(temp / "denials.jsonl")

        base = temp / "repo"
        outside_worktree = temp / "repo-worktree"
        nested_worktree = base / ".worktrees" / "nested"
        external_file = temp / "external-config.json"

        run(["git", "init", "-q", str(base)])
        run(["git", "-C", str(base), "config", "user.email", "probe@example.com"])
        run(["git", "-C", str(base), "config", "user.name", "Probe"])
        (base / "README.md").write_text("hello\n", encoding="utf-8")
        run(["git", "-C", str(base), "add", "README.md"])
        run(["git", "-C", str(base), "commit", "-q", "-m", "init"])
        run(["git", "-C", str(base), "branch", "-M", "main"])
        run(["git", "-C", str(base), "worktree", "add", "-q", "-b", "task-out", str(outside_worktree)])
        run(["git", "-C", str(base), "worktree", "add", "-q", "-b", "task-nested", str(nested_worktree)])
        external_file.write_text('{"enabled": true}\n', encoding="utf-8")

        cases = [
            (
                "deny base reset",
                "deny",
                {
                    "cwd": str(base),
                    "tool_name": "Bash",
                    "tool_input": {"command": "git reset --hard HEAD"},
                },
            ),
            (
                "allow base pull",
                "allow",
                {
                    "cwd": str(base),
                    "tool_name": "Bash",
                    "tool_input": {"command": "git pull --ff-only"},
                },
            ),
            (
                "allow base merge",
                "allow",
                {
                    "cwd": str(base),
                    "tool_name": "Bash",
                    "tool_input": {"command": "git merge --ff-only main"},
                },
            ),
            (
                "allow worktree add",
                "allow",
                {
                    "cwd": str(base),
                    "tool_name": "Bash",
                    "tool_input": {"command": f"git worktree add -b another {temp / 'another'} main"},
                },
            ),
            (
                "allow cd outside worktree then reset",
                "allow",
                {
                    "cwd": str(base),
                    "tool_name": "Bash",
                    "tool_input": {"command": f"cd {outside_worktree} && git reset --hard HEAD"},
                },
            ),
            (
                "allow cd nested worktree then reset",
                "allow",
                {
                    "cwd": str(base),
                    "tool_name": "Bash",
                    "tool_input": {"command": f"cd {nested_worktree} && git reset --hard HEAD"},
                },
            ),
            (
                "allow git switch in workdir worktree",
                "allow",
                {
                    "cwd": str(base),
                    "tool_name": "Bash",
                    "tool_input": {
                        "workdir": str(outside_worktree),
                        "command": "git switch task-out",
                    },
                },
            ),
            (
                "allow non-git shell command",
                "allow",
                {
                    "cwd": str(base),
                    "tool_name": "Bash",
                    "tool_input": {"command": "find . -name README.md -print"},
                },
            ),
            (
                "allow apply_patch external target",
                "allow",
                {
                    "cwd": str(base),
                    "tool_name": "apply_patch",
                    "tool_input": {
                        "command": patch("Update File", external_file),
                    },
                },
            ),
            (
                "allow apply_patch linked worktree target",
                "allow",
                {
                    "cwd": str(base),
                    "tool_name": "apply_patch",
                    "tool_input": {
                        "command": patch("Update File", outside_worktree / "README.md"),
                    },
                },
            ),
            (
                "deny apply_patch base target",
                "deny",
                {
                    "cwd": str(base),
                    "tool_name": "apply_patch",
                    "tool_input": {
                        "command": patch("Update File", base / "README.md"),
                    },
                },
            ),
        ]

        failures = []
        for name, expected, payload in cases:
            payload["session_id"] = "probe"
            actual, stdout, stderr = hook_decision(payload, env)
            print(f"{actual.upper():5} {name}")
            if actual != expected:
                failures.append((name, expected, actual, stdout, stderr))

        if failures:
            for name, expected, actual, stdout, stderr in failures:
                print(f"\nFAIL {name}: expected {expected}, got {actual}", file=sys.stderr)
                if stdout:
                    print(stdout, file=sys.stderr)
                if stderr:
                    print(stderr, file=sys.stderr)
            return 1
        return 0
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def patch(kind: str, path: Path) -> str:
    return f"*** Begin Patch\n*** {kind}: {path}\n@@\n*** End Patch\n"


def hook_decision(payload: dict[str, object], env: dict[str, str]) -> tuple[str, str, str]:
    result = subprocess.run(
        [str(WTG), "hook", "codex", "pre-tool-use"],
        input=json.dumps(payload).encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=False,
    )
    stdout = result.stdout.decode()
    stderr = result.stderr.decode()
    if result.returncode != 0:
        return "error", stdout, stderr
    if not stdout.strip():
        return "allow", stdout, stderr
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        return "error", stdout, stderr
    hook_output = data.get("hookSpecificOutput")
    if isinstance(hook_output, dict) and hook_output.get("permissionDecision") == "deny":
        return "deny", stdout, stderr
    return "allow", stdout, stderr


def run(args: list[str]) -> None:
    subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


if __name__ == "__main__":
    raise SystemExit(main())

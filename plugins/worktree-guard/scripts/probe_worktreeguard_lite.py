#!/usr/bin/env python3
"""Hook-level regression probe for WorktreeGuard-lite.

This exercises the same JSON hook surface Codex and Claude Code use (policy
logic is shared; each case runs through both harness dispatchers). A denied
hook exits successfully and carries the denial in stdout, so this probe
parses the hook decision instead of treating exit code 0 as success.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
WTG = ROOT / "bin" / "wtg"


@dataclass(frozen=True)
class Case:
    name: str
    expected: str
    payload: dict[str, Any]


def main() -> int:
    temp = Path(tempfile.mkdtemp(prefix="wtg-probe-")).resolve()
    try:
        env = os.environ.copy()
        env["WTG_STATE_FILE"] = str(temp / "state.json")
        env["WTG_ACTION_LOG_FILE"] = str(temp / "actions.jsonl")
        env["WTG_DENY_LOG_FILE"] = str(temp / "denials.jsonl")

        paths = make_repo_fixture(temp)
        cases = build_cases(paths)

        failures = []
        for index, case in enumerate(cases, start=1):
            payload = dict(case.payload)
            payload["session_id"] = "probe"
            payload["turn_id"] = f"case-{index}"
            actual, stdout, stderr = hook_decision(payload, env)
            print(f"{actual.upper():5} {case.name}")
            if actual != case.expected:
                failures.append((case, actual, stdout, stderr))

        for index, case in enumerate(cases, start=1):
            payload = dict(case.payload)
            payload["session_id"] = "probe-claude"
            payload["turn_id"] = f"claude-case-{index}"
            actual, stdout, stderr = hook_decision(payload, env, harness="claude")
            print(f"{actual.upper():5} [claude] {case.name}")
            if actual != case.expected:
                failures.append((case, actual, stdout, stderr))

        records = read_jsonl(Path(env["WTG_ACTION_LOG_FILE"]))
        if len(records) != len(cases) * 2:
            failures.append(
                (
                    Case(
                        name="action log records every checked hook",
                        expected=str(len(cases) * 2),
                        payload={},
                    ),
                    str(len(records)),
                    "",
                    "",
                )
            )

        if failures:
            for case, actual, stdout, stderr in failures:
                print(f"\nFAIL {case.name}: expected {case.expected}, got {actual}", file=sys.stderr)
                if stdout:
                    print(stdout, file=sys.stderr)
                if stderr:
                    print(stderr, file=sys.stderr)
            return 1
        print(
            f"PASS {len(cases)} hook decisions x2 harnesses (codex, claude); "
            f"action log records={len(records)}"
        )
        return 0
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def make_repo_fixture(temp: Path) -> dict[str, Path]:
    base = temp / "repo"
    outside_worktree = temp / "repo-worktree"
    nested_worktree = base / ".worktrees" / "nested"
    external_dir = temp / "external"
    external_file = external_dir / "config.json"
    missing = temp / "missing-worktree"

    run(["git", "init", "-q", str(base)])
    run(["git", "-C", str(base), "config", "user.email", "probe@example.com"])
    run(["git", "-C", str(base), "config", "user.name", "Probe"])
    (base / "README.md").write_text("hello\n", encoding="utf-8")
    run(["git", "-C", str(base), "add", "README.md"])
    run(["git", "-C", str(base), "commit", "-q", "-m", "init"])
    run(["git", "-C", str(base), "branch", "-M", "main"])
    run(["git", "-C", str(base), "worktree", "add", "-q", "-b", "task-out", str(outside_worktree)])
    run(["git", "-C", str(base), "worktree", "add", "-q", "-b", "task-nested", str(nested_worktree)])
    external_dir.mkdir()
    external_file.write_text('{"enabled": true}\n', encoding="utf-8")

    return {
        "temp": temp,
        "base": base,
        "outside_worktree": outside_worktree,
        "nested_worktree": nested_worktree,
        "external_dir": external_dir,
        "external_file": external_file,
        "missing": missing,
    }


def build_cases(paths: dict[str, Path]) -> list[Case]:
    temp = paths["temp"]
    base = paths["base"]
    outside = paths["outside_worktree"]
    nested = paths["nested_worktree"]
    external_dir = paths["external_dir"]
    external_file = paths["external_file"]
    missing = paths["missing"]

    cases: list[Case] = [
        bash("deny base reset", "deny", base, "git reset --hard HEAD"),
        bash("deny base checkout", "deny", base, "git checkout -b denied"),
        bash("deny base switch", "deny", base, "git switch -c denied"),
        bash("deny base clean", "deny", base, "git clean -fd"),
        bash("deny base restore", "deny", base, "git restore README.md"),
        bash("deny base rebase", "deny", base, "git rebase main"),
        bash("deny command-wrapped reset", "deny", base, "command git reset --hard HEAD"),
        bash("deny env-wrapped reset", "deny", base, "env FOO=1 git reset --hard HEAD"),
        bash("deny sudo-wrapped restore", "deny", base, "sudo -n git restore README.md"),
        bash("deny time-wrapped reset", "deny", base, "time git reset --hard HEAD"),
        bash("deny bash -c reset", "deny", base, "bash -lc 'git reset --hard HEAD'"),
        bash("deny sh -c switch", "deny", base, "sh -c 'git switch main'"),
        bash("deny git config option reset", "deny", base, "git -c core.editor=true reset --hard HEAD"),
        bash("deny git no-pager reset", "deny", base, "git --no-pager reset --hard HEAD"),
        bash("deny git no-optional-locks reset", "deny", base, "git --no-optional-locks reset --hard HEAD"),
        bash(
            "deny git work-tree equals reset",
            "deny",
            base,
            f"git --work-tree={base} --git-dir={base / '.git'} reset --hard HEAD",
        ),
        bash(
            "deny git work-tree reset from external cwd",
            "deny",
            external_dir,
            f"git --work-tree {base} --git-dir {base / '.git'} reset --hard HEAD",
        ),
        bash("deny git -C base reset", "deny", temp, f"git -C {base} reset --hard HEAD"),
        bash("allow base fetch", "allow", base, "git fetch --prune origin"),
        bash("allow base pull", "allow", base, "git pull --ff-only"),
        bash("allow base merge", "allow", base, "git merge --ff-only main"),
        bash("allow base worktree add", "allow", base, f"git worktree add -b another {temp / 'another'} main"),
        bash("allow base worktree remove", "allow", base, f"git worktree remove {outside}"),
        bash("allow base add", "allow", base, "git add README.md"),
        bash("allow base commit", "allow", base, "git commit -m probe"),
        bash("allow base branch delete shape", "allow", base, "git branch -D stale"),
        bash("allow base stash push shape", "allow", base, "git stash push -u -m probe"),
        bash("allow non-git find delete shape", "allow", base, "find . -name README.md -delete"),
        bash("allow non-git rm shape", "allow", base, "rm README.md"),
        bash("allow non-git sed in-place shape", "allow", base, "sed -i s/a/b/ README.md"),
        bash("allow non-git touch shape", "allow", base, "touch created.txt"),
        bash("allow non-git python write shape", "allow", base, "python3 -c 'open(\"x\", \"w\").write(\"x\")'"),
        bash("allow cd outside worktree then reset", "allow", base, f"cd {outside} && git reset --hard HEAD"),
        bash("allow cd outside worktree semicolon reset", "allow", base, f"cd {outside}; git reset --hard HEAD"),
        bash("allow builtin cd outside worktree then reset", "allow", base, f"builtin cd {outside} && git reset --hard HEAD"),
        bash("allow cd nested worktree then reset", "allow", base, f"cd {nested} && git reset --hard HEAD"),
        bash("allow git -C outside worktree reset", "allow", base, f"git -C {outside} reset --hard HEAD"),
        bash("allow git -C nested worktree switch", "allow", base, f"git -C {nested} switch task-nested"),
        bash(
            "allow tool workdir outside worktree switch",
            "allow",
            base,
            "git switch task-out",
            workdir=outside,
        ),
        bash(
            "allow tool workdir nested worktree checkout",
            "allow",
            base,
            "git checkout task-nested",
            workdir=nested,
        ),
        bash("deny missing cd fallback reset", "deny", base, f"cd {missing} || git reset --hard HEAD"),
        bash("deny pipe does not carry cd cwd", "deny", base, f"cd {outside} | git reset --hard HEAD"),
        bash("deny or does not carry cd cwd", "deny", base, f"cd {outside} || git reset --hard HEAD"),
        patch_case("deny apply_patch base update", "deny", base, patch("Update File", base / "README.md")),
        patch_case("deny apply_patch base add", "deny", base, patch("Add File", base / "NEW.md")),
        patch_case("deny apply_patch base delete", "deny", base, patch("Delete File", base / "README.md")),
        patch_case("deny apply_patch relative base update", "deny", base, patch("Update File", Path("README.md"))),
        patch_case("allow apply_patch external absolute", "allow", base, patch("Update File", external_file)),
        patch_case(
            "allow apply_patch external relative workdir",
            "allow",
            base,
            patch("Update File", Path("config.json")),
            workdir=external_dir,
        ),
        patch_case("allow apply_patch outside worktree target", "allow", base, patch("Update File", outside / "README.md")),
        patch_case("allow apply_patch nested worktree target", "allow", base, patch("Update File", nested / "README.md")),
        patch_case(
            "deny apply_patch nested path traversal to base",
            "deny",
            base,
            patch("Update File", Path("../../README.md")),
            workdir=nested,
        ),
        patch_case(
            "deny apply_patch mixed base and external",
            "deny",
            base,
            patch("Update File", external_file) + patch("Update File", base / "README.md"),
        ),
        patch_case(
            "allow apply_patch move external to worktree",
            "allow",
            base,
            move_patch(external_file, outside / "config.json"),
        ),
        patch_case(
            "deny apply_patch move external to base",
            "deny",
            base,
            move_patch(external_file, base / "config.json"),
        ),
        write_tool("allow Edit external file path", "allow", base, "Edit", {"file_path": str(external_file)}),
        write_tool("deny Edit base file path", "deny", base, "Edit", {"file_path": str(base / "README.md")}),
        write_tool("allow Write worktree path", "allow", base, "Write", {"path": str(outside / "created.txt")}),
        write_tool("deny Write base path", "deny", base, "Write", {"path": str(base / "created.txt")}),
        write_tool("allow unknown Write outside cwd", "allow", external_dir, "Write", {}),
        write_tool("deny unknown Write protected cwd", "deny", base, "Write", {}),
        tool("allow MCP read shape", "allow", base, "mcp__server__read_file", {}),
        tool("allow MCP list shape", "allow", base, "mcp__server__list_files", {}),
        tool("deny MCP write shape", "deny", base, "mcp__server__write_file", {}),
    ]
    return cases


def bash(name: str, expected: str, cwd: Path, command: str, *, workdir: Path | None = None) -> Case:
    tool_input: dict[str, Any] = {"command": command}
    if workdir is not None:
        tool_input["workdir"] = str(workdir)
    return Case(name, expected, {"cwd": str(cwd), "tool_name": "Bash", "tool_input": tool_input})


def patch_case(
    name: str,
    expected: str,
    cwd: Path,
    command: str,
    *,
    workdir: Path | None = None,
) -> Case:
    tool_input: dict[str, Any] = {"command": command}
    if workdir is not None:
        tool_input["workdir"] = str(workdir)
    return Case(name, expected, {"cwd": str(cwd), "tool_name": "apply_patch", "tool_input": tool_input})


def write_tool(name: str, expected: str, cwd: Path, tool_name: str, tool_input: dict[str, Any]) -> Case:
    return Case(name, expected, {"cwd": str(cwd), "tool_name": tool_name, "tool_input": tool_input})


def tool(name: str, expected: str, cwd: Path, tool_name: str, tool_input: dict[str, Any]) -> Case:
    return Case(name, expected, {"cwd": str(cwd), "tool_name": tool_name, "tool_input": tool_input})


def patch(kind: str, path: Path) -> str:
    return f"*** Begin Patch\n*** {kind}: {path}\n@@\n*** End Patch\n"


def move_patch(source: Path, destination: Path) -> str:
    return (
        "*** Begin Patch\n"
        f"*** Update File: {source}\n"
        f"*** Move to: {destination}\n"
        "@@\n"
        "*** End Patch\n"
    )


def hook_decision(
    payload: dict[str, Any], env: dict[str, str], *, harness: str = "codex"
) -> tuple[str, str, str]:
    result = subprocess.run(
        [str(WTG), "hook", harness, "pre-tool-use"],
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


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    records: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        records.append(json.loads(line))
    return records


def run(args: list[str]) -> None:
    subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


if __name__ == "__main__":
    raise SystemExit(main())

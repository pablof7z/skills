#!/usr/bin/env python3
"""Regression probe for WorktreeGuard's deliberately small contract."""

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
BLOCKED = ("checkout", "clean", "rebase", "reset", "restore", "switch")


@dataclass(frozen=True)
class Case:
    name: str
    expected: str
    payload: dict[str, Any]
    event: str = "pre-tool-use"


def main() -> int:
    temp = Path(tempfile.mkdtemp(prefix="wtg-probe-")).resolve()
    failures: list[str] = []
    try:
        env = os.environ.copy()
        env["WTG_STATE_FILE"] = str(temp / "state.json")
        env["WTG_DENY_LOG_FILE"] = str(temp / "denials.jsonl")
        base, linked = make_repo(temp)
        failures.extend(manifest_failures())
        failures.extend(shim_failures(temp))

        cases = contract_cases(temp, base, linked)
        expected_denials = 0
        for harness in ("codex", "claude"):
            for index, case in enumerate(cases):
                payload = {
                    "session_id": f"probe-{harness}",
                    "turn_id": f"{harness}-{index}",
                    **case.payload,
                }
                actual, details = decision(harness, case.event, payload, env)
                print(f"{actual.upper():5} [{harness}] {case.name}")
                if case.expected == "deny":
                    expected_denials += 1
                if actual != case.expected:
                    failures.append(
                        f"{harness} {case.name}: expected {case.expected}, got {actual}: {details}"
                    )

        failures.extend(once_override_failures(base, env))
        expected_denials += 1
        records = read_jsonl(Path(env["WTG_DENY_LOG_FILE"]))
        if len(records) != expected_denials:
            failures.append(
                f"denial log: expected {expected_denials} records, got {len(records)}"
            )
        if any(record.get("subcommand") not in BLOCKED for record in records):
            failures.append("denial log contains a command outside the explicit denylist")

        if failures:
            print("\n".join(f"FAIL {failure}" for failure in failures), file=sys.stderr)
            return 1
        print(f"PASS {len(cases) * 2 + 2} decisions; denials logged={len(records)}")
        return 0
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def make_repo(temp: Path) -> tuple[Path, Path]:
    base = temp / "repo"
    linked = temp / "repo-linked"
    run(["git", "init", "-q", "-b", "main", str(base)])
    run(["git", "config", "user.email", "probe@example.com"], cwd=base)
    run(["git", "config", "user.name", "Probe"], cwd=base)
    (base / "README.md").write_text("probe\n", encoding="utf-8")
    run(["git", "add", "README.md"], cwd=base)
    run(["git", "commit", "-q", "-m", "initial"], cwd=base)
    run(["git", "worktree", "add", "-q", "-b", "probe-linked", str(linked)], cwd=base)
    return base, linked


def contract_cases(temp: Path, base: Path, linked: Path) -> list[Case]:
    cases = [
        Case(f"blocks git {command} in base", "deny", shell(base, f"git {command}"))
        for command in BLOCKED
    ]
    cases += [
        Case(f"allows git {command} in linked worktree", "allow", shell(linked, f"git {command}"))
        for command in BLOCKED
    ]
    cases += [
        Case(f"allows git {command} in base", "allow", shell(base, f"git {command}"))
        for command in ("add .", "commit -m probe", "fetch", "merge main", "pull", "worktree list")
    ]
    cases += [
        Case("allows non-Git shell command", "allow", shell(base, "printf hello")),
        Case("honors git -C base", "deny", shell(temp, f"git -C {base} reset --hard")),
        Case("honors simple cd then Git", "deny", shell(temp, f"cd {base} && git switch main")),
        Case("honors linked hook workdir", "allow", shell(base, "git reset", workdir=linked)),
        Case(
            "ignores non-shell tools",
            "allow",
            {"cwd": str(base), "tool_name": "mcp__anything", "tool_input": {"command": "git reset"}},
        ),
        Case("malformed shell fails open", "allow", shell(base, "git 'reset")),
        Case("permission hook uses same narrow policy", "deny", shell(base, "git restore ."), "permission-request"),
    ]
    return cases


def shell(cwd: Path, command: str, *, workdir: Path | None = None) -> dict[str, Any]:
    tool_input: dict[str, Any] = {"command": command}
    if workdir is not None:
        tool_input["workdir"] = str(workdir)
    return {"cwd": str(cwd), "tool_name": "Bash", "tool_input": tool_input}


def manifest_failures() -> list[str]:
    hooks = json.loads((ROOT / "hooks/hooks.json").read_text(encoding="utf-8"))["hooks"]
    failures: list[str] = []
    if set(hooks) != {"PreToolUse", "PermissionRequest"}:
        failures.append(f"unexpected hook events: {sorted(hooks)}")
    for event in ("PreToolUse", "PermissionRequest"):
        if hooks[event][0].get("matcher") != "Bash|Shell":
            failures.append(f"{event} matcher is not exactly Bash|Shell")
    return failures


def shim_failures(temp: Path) -> list[str]:
    fake = temp / "fake-wtg"
    fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n', encoding="utf-8")
    fake.chmod(0o755)
    env = {**os.environ, "WTG_BIN": str(fake)}
    scenarios = (
        ("wtg-hook-codex", {}, "hook codex pre-tool-use"),
        ("wtg-hook-claude", {"transcript_path": "/tmp/.claude/session.jsonl"}, "hook claude pre-tool-use"),
        ("wtg-hook-claude", {"transcript_path": "/tmp/.codex/session.jsonl"}, "hook codex pre-tool-use"),
    )
    failures: list[str] = []
    for shim, payload, expected in scenarios:
        result = subprocess.run(
            [str(ROOT / "bin" / shim), "pre-tool-use"], input=json.dumps(payload),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, check=False,
        )
        actual = result.stdout.strip()
        print(f"{actual.upper():27} {shim} routes to shared WorktreeGuard")
        if result.returncode != 0 or actual != expected:
            failures.append(f"{shim} routing expected {expected}, got {actual or result.stderr}")
    return failures


def once_override_failures(base: Path, env: dict[str, str]) -> list[str]:
    approval_env = {**env, "WTG_APPROVAL_RESPONSE": "once"}
    result = subprocess.run(
        [str(WTG), "request-base-access", "--repo", str(base), "--reason", "probe"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=approval_env, check=False,
    )
    if result.returncode != 0:
        return [f"once override request failed: {result.stderr}"]
    payload = {"session_id": "grant", **shell(base, "git reset --hard")}
    first, _ = decision("codex", "pre-tool-use", payload, env)
    second, _ = decision("codex", "pre-tool-use", payload, env)
    print(f"{first.upper():5} [codex] once override permits first blocked command")
    print(f"{second.upper():5} [codex] once override is consumed")
    return [] if (first, second) == ("allow", "deny") else [
        f"once override expected allow then deny, got {first} then {second}"
    ]


def decision(
    harness: str, event: str, payload: dict[str, Any], env: dict[str, str]
) -> tuple[str, str]:
    result = subprocess.run(
        [str(WTG), "hook", harness, event], input=json.dumps(payload),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, check=False,
    )
    if result.returncode != 0:
        return "error", result.stderr
    if not result.stdout.strip():
        return "allow", ""
    try:
        output = json.loads(result.stdout)["hookSpecificOutput"]
    except (json.JSONDecodeError, KeyError):
        return "error", result.stdout
    if event == "permission-request":
        return output.get("decision", {}).get("behavior", "allow"), result.stdout
    return output.get("permissionDecision", "allow"), result.stdout


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    raise SystemExit(main())

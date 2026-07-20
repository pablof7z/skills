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
NATIVE_WRITES = ("apply_patch", "Edit", "Write", "MultiEdit", "NotebookEdit")


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
        env["WTG_NOTIFICATION_LOG_FILE"] = str(temp / "notifications.jsonl")
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

        failures.extend(auto_grant_setting_failures(base, env))
        expected_denials += 2
        failures.extend(notification_failures(Path(env["WTG_NOTIFICATION_LOG_FILE"])))
        failures.extend(once_override_failures(base, env))
        expected_denials += 1
        records = read_jsonl(Path(env["WTG_DENY_LOG_FILE"]))
        if len(records) != expected_denials:
            failures.append(
                f"denial log: expected {expected_denials} records, got {len(records)}"
            )
        if any(not valid_denial(record) for record in records):
            failures.append("denial log contains an operation outside the policy")

        if failures:
            print("\n".join(f"FAIL {failure}" for failure in failures), file=sys.stderr)
            return 1
        print(f"PASS {len(cases) * 2 + 4} decisions; denials logged={len(records)}")
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
        Case("allows direct shell file write", "allow", shell(base, "rm README.md")),
        Case("honors git -C base", "deny", shell(temp, f"git -C {base} reset --hard")),
        Case("honors simple cd then Git", "deny", shell(temp, f"cd {base} && git switch main")),
        Case("honors linked hook workdir", "allow", shell(base, "git reset", workdir=linked)),
        Case(
            "ignores MCP tools",
            "allow",
            {"cwd": str(base), "tool_name": "mcp__anything", "tool_input": {"command": "git reset"}},
        ),
        Case("auto-grants Edit target in base", "allow", native(base, "Edit", file_path=base / "README.md")),
        Case("auto-grants Write target in base", "allow", native(base, "Write", path=base / "created.txt")),
        Case("auto-grants MultiEdit target in base", "allow", native(base, "MultiEdit", file_path="README.md")),
        Case("auto-grants NotebookEdit target in base", "allow", native(base, "NotebookEdit", notebook_path=base / "notes.ipynb")),
        Case("auto-grants apply_patch target in base", "allow", patch(base, "*** Update File: README.md")),
        Case(
            "auto-grants raw apply_patch input in base",
            "allow",
            {
                "cwd": str(base),
                "tool_name": "apply_patch",
                "tool_input": "*** Begin Patch\n*** Add File: raw.txt\n*** End Patch",
            },
        ),
        Case("allows Edit target in linked worktree", "allow", native(base, "Edit", file_path=linked / "README.md")),
        Case("allows Write target outside checkout", "allow", native(base, "Write", path=temp / "outside.txt")),
        Case("allows apply_patch target in linked worktree", "allow", patch(linked, "*** Add File: linked.txt")),
        Case("auto-grants targetless native write from base", "allow", native(base, "Write")),
        Case("allows targetless native write from worktree", "allow", native(linked, "Write")),
        Case("malformed shell fails open", "allow", shell(base, "git 'reset")),
        Case("permission hook explicitly auto-grants", "allow", native(base, "Edit", file_path=base / "README.md"), "permission-request"),
    ]
    return cases


def shell(cwd: Path, command: str, *, workdir: Path | None = None) -> dict[str, Any]:
    tool_input: dict[str, Any] = {"command": command}
    if workdir is not None:
        tool_input["workdir"] = str(workdir)
    return {"cwd": str(cwd), "tool_name": "Bash", "tool_input": tool_input}


def native(cwd: Path, tool_name: str, **values: Path | str) -> dict[str, Any]:
    return {
        "cwd": str(cwd),
        "tool_name": tool_name,
        "tool_input": {key: str(value) for key, value in values.items()},
    }


def patch(cwd: Path, body: str) -> dict[str, Any]:
    return native(cwd, "apply_patch", patch=f"*** Begin Patch\n{body}\n*** End Patch")


def manifest_failures() -> list[str]:
    hooks = json.loads((ROOT / "hooks/hooks.json").read_text(encoding="utf-8"))["hooks"]
    failures: list[str] = []
    if set(hooks) != {"PreToolUse", "PermissionRequest"}:
        failures.append(f"unexpected hook events: {sorted(hooks)}")
    matcher = "Bash|Shell|apply_patch|Edit|Write|MultiEdit|NotebookEdit"
    for event in ("PreToolUse", "PermissionRequest"):
        if hooks[event][0].get("matcher") != matcher:
            failures.append(f"{event} matcher does not cover the native write tools")
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


def auto_grant_setting_failures(base: Path, env: dict[str, str]) -> list[str]:
    failures: list[str] = []
    for value in ("off", "on"):
        result = subprocess.run(
            [str(WTG), "config", "auto-grant-edits", value],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=env, check=False,
        )
        if result.returncode != 0 or f"auto-grant-edits: {value}" not in result.stdout:
            failures.append(f"config auto-grant-edits {value} failed: {result.stderr}")
        if value == "off":
            for harness in ("codex", "claude"):
                payload = {"session_id": f"disabled-{harness}", **native(
                    base, "Edit", file_path=base / "README.md"
                )}
                actual, details = decision(harness, "pre-tool-use", payload, env)
                print(f"{actual.upper():5} [{harness}] disabled auto-grant blocks base edit")
                if actual != "deny":
                    failures.append(
                        f"{harness} disabled auto-grant expected deny, got {actual}: {details}"
                    )
    return failures


def notification_failures(path: Path) -> list[str]:
    records = read_jsonl(path)
    sessions = {record.get("session_id") for record in records}
    expected = {"probe-codex", "probe-claude"}
    print(f"NOTIFY native base-edit auto grants: {len(records)} session notices")
    if len(records) != 2 or sessions != expected:
        return [f"notifications expected one per harness session, got {records}"]
    if any("granted itself" not in str(record.get("message")) for record in records):
        return ["notification does not explain that the agent granted itself permission"]
    return []


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


def valid_denial(record: dict[str, Any]) -> bool:
    return record.get("subcommand") in BLOCKED or record.get("tool_name") in NATIVE_WRITES


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    raise SystemExit(main())

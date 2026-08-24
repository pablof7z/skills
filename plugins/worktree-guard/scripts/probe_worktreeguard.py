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

from hook_contracts import denial_decision


ROOT = Path(__file__).resolve().parents[1]
WTG = ROOT / "bin" / "wtg"
BLOCKED = ("checkout", "clean", "rebase", "reset", "restore", "switch")
NATIVE_WRITES = (
    "apply_patch", "Edit", "Write", "MultiEdit", "NotebookEdit", "search_replace",
)


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
        env["WTG_REQUEST_LOG_FILE"] = str(temp / "requests.jsonl")
        env["WTG_NOTIFICATION_LOG_FILE"] = str(temp / "notifications.jsonl")
        base, linked = make_repo(temp)
        failures.extend(manifest_failures())
        failures.extend(shim_failures(temp))

        cases = contract_cases(temp, base, linked)
        expected_denials = 0
        for harness in ("codex", "claude", "grok"):
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

        failures.extend(bypass_setting_failures(base, env))
        expected_denials += 6  # codex, claude, grok unrequested base-edit denials x2 (bypass on/off)
        failures.extend(request_grant_failures(base, env))
        expected_denials += 1
        failures.extend(session_approval_failures(base, env))
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
        print(f"PASS {len(cases) * 3 + 12} decisions; denials logged={len(records)}")
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
        Case("blocks unrequested Edit target in base", "deny", native(base, "Edit", file_path=base / "README.md")),
        Case("blocks unrequested Write target in base", "deny", native(base, "Write", path=base / "created.txt")),
        Case("blocks unrequested MultiEdit target in base", "deny", native(base, "MultiEdit", file_path="README.md")),
        Case("blocks unrequested NotebookEdit target in base", "deny", native(base, "NotebookEdit", notebook_path=base / "notes.ipynb")),
        Case(
            "blocks unrequested search_replace target in base",
            "deny",
            native(base, "search_replace", file_path=base / "README.md"),
        ),
        Case(
            "blocks unrequested Grok shell git checkout in base",
            "deny",
            {
                "cwd": str(base),
                "tool_name": "run_terminal_command",
                "tool_input": {"command": "git checkout -b probe"},
            },
        ),
        Case(
            "blocks camelCase Grok shell git checkout in base",
            "deny",
            {
                "cwd": str(base),
                "toolName": "run_terminal_command",
                "toolInput": {"command": "git checkout -b probe"},
            },
        ),
        Case("blocks unrequested apply_patch target in base", "deny", patch(base, "*** Update File: README.md")),
        Case(
            "blocks unrequested raw apply_patch input in base",
            "deny",
            {
                "cwd": str(base),
                "tool_name": "apply_patch",
                "tool_input": "*** Begin Patch\n*** Add File: raw.txt\n*** End Patch",
            },
        ),
        Case("allows Edit target in linked worktree", "allow", native(base, "Edit", file_path=linked / "README.md")),
        Case("allows Write target outside checkout", "allow", native(base, "Write", path=temp / "outside.txt")),
        Case("allows apply_patch target in linked worktree", "allow", patch(linked, "*** Add File: linked.txt")),
        Case("blocks targetless native write from base", "deny", native(base, "Write")),
        Case("allows targetless native write from worktree", "allow", native(linked, "Write")),
        Case("malformed shell fails open", "allow", shell(base, "git 'reset")),
        Case("ignores harness permission events", "allow", native(base, "Edit", file_path=base / "README.md"), "permission-request"),
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
    if set(hooks) != {"PreToolUse"}:
        failures.append(f"unexpected hook events: {sorted(hooks)}")
    matcher = (
        "Bash|Shell|run_terminal_command|run_terminal_cmd|apply_patch|"
        "Edit|Write|MultiEdit|NotebookEdit|search_replace"
    )
    if hooks["PreToolUse"][0].get("matcher") != matcher:
        failures.append("PreToolUse matcher does not cover the native write tools")
    return failures


def shim_failures(temp: Path) -> list[str]:
    fake = temp / "fake-wtg"
    fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n', encoding="utf-8")
    fake.chmod(0o755)
    harness_markers = {
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_PLUGIN_ROOT", "CODEX_THREAD_ID",
        "GROK_PLUGIN_ROOT", "GROK_SESSION_ID", "PLUGIN_ROOT",
    }
    env = {
        **{key: value for key, value in os.environ.items() if key not in harness_markers},
        "WTG_BIN": str(fake),
    }
    scenarios = (
        ("wtg-hook-codex", {}, "hook codex pre-tool-use"),
        ("wtg-hook-claude", {"transcript_path": "/tmp/.claude/session.jsonl"}, "hook claude pre-tool-use"),
        ("wtg-hook-claude", {"transcript_path": "/tmp/.codex/session.jsonl"}, "hook codex pre-tool-use"),
        ("wtg-hook-grok", {}, "hook grok pre-tool-use"),
        ("wtg-hook-dispatch", {"GROK_SESSION_ID": "g1"}, "hook grok pre-tool-use"),
        ("wtg-hook-dispatch", {"PLUGIN_ROOT": "/tmp/plugin"}, "hook codex pre-tool-use"),
        ("wtg-hook-dispatch", {"CLAUDE_PLUGIN_ROOT": "/tmp/plugin"}, "hook claude pre-tool-use"),
    )
    failures: list[str] = []
    for shim, payload_or_env, expected in scenarios:
        if shim == "wtg-hook-dispatch":
            run_env = {**env, **payload_or_env}
            payload: dict[str, Any] = {}
        else:
            run_env = env
            payload = payload_or_env
        result = subprocess.run(
            [str(ROOT / "bin" / shim), "pre-tool-use"], input=json.dumps(payload),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=run_env, check=False,
        )
        actual = result.stdout.strip()
        print(f"{actual.upper():27} {shim} routes to shared WorktreeGuard")
        if result.returncode != 0 or actual != expected:
            failures.append(f"{shim} routing expected {expected}, got {actual or result.stderr}")
    return failures


def session_approval_failures(base: Path, env: dict[str, str]) -> list[str]:
    """With bypass=manual, the request falls back to asking the local human."""
    set_group_bypass(env, "discard", "manual")
    approval_env = {
        **env, "WTG_APPROVAL_RESPONSE": "session", "WTG_SESSION_ID": "approved-session",
    }
    result = subprocess.run(
        [
            str(WTG), "request-base-access", "--repo", str(base),
            "--group", "discard", "--reason", "probe",
        ],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=approval_env, check=False,
    )
    if result.returncode != 0:
        return [f"session override request failed: {result.stderr}"]
    payload = {"session_id": "approved-session", **shell(base, "git reset --hard")}
    first, _ = decision("codex", "pre-tool-use", payload, env)
    second, _ = decision("codex", "pre-tool-use", payload, env)
    other, _ = decision(
        "codex", "pre-tool-use",
        {"session_id": "other-session", **shell(base, "git reset --hard")}, env,
    )
    print(f"{first.upper():5} [codex] session override permits first blocked command")
    print(f"{second.upper():5} [codex] session override permits later blocked command")
    print(f"{other.upper():5} [codex] session override does not leak")
    return [] if (first, second, other) == ("allow", "allow", "deny") else [
        f"session override expected allow, allow, deny; got {first}, {second}, {other}"
    ]


def bypass_setting_failures(base: Path, env: dict[str, str]) -> list[str]:
    failures: list[str] = []
    for value in ("manual", "auto"):
        result = subprocess.run(
            [str(WTG), "config", "--repo", str(base), "set", "writes.bypass", value],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=env, check=False,
        )
        if result.returncode != 0 or f'"bypass":"{value}"' not in result.stdout.replace(" ", ""):
            failures.append(f"config set writes.bypass {value} failed: {result.stderr}")
        # An unrequested base edit is denied regardless of the bypass setting.
        for harness in ("codex", "claude", "grok"):
            payload = {"session_id": f"unrequested-{harness}", **native(
                base, "Edit", file_path=base / "README.md"
            )}
            actual, details = decision(harness, "pre-tool-use", payload, env)
            print(f"{actual.upper():5} [{harness}] unrequested base edit blocked (writes.bypass={value})")
            if actual != "deny":
                failures.append(
                    f"{harness} unrequested edit expected deny, got {actual}: {details}"
                )
    return failures


def request_grant_failures(base: Path, env: dict[str, str]) -> list[str]:
    """An explicit request is what auto-grants; the write alone never does."""
    set_group_bypass(env, "writes", "auto")
    request_env = {**env, "WTG_SESSION_ID": "granted-session"}
    result = subprocess.run(
        [
            str(WTG), "request-base-access", "--repo", str(base),
            "--group", "writes", "--reason", "probe grant",
        ],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=request_env, check=False,
    )
    if result.returncode != 0:
        return [f"auto-granted request failed: {result.stderr}"]

    failures = notification_failures(Path(env["WTG_NOTIFICATION_LOG_FILE"]))
    for name, payload in (
        ("native edit", native(base, "Edit", file_path=base / "README.md")),
        ("git reset", shell(base, "git reset --hard")),
    ):
        actual, details = decision(
            "claude", "pre-tool-use", {"session_id": "granted-session", **payload}, env
        )
        print(f"{actual.upper():5} [claude] granted session permits {name} in base")
        if actual != "allow":
            failures.append(f"granted session {name} expected allow, got {actual}: {details}")

    actual, details = decision(
        "claude", "pre-tool-use",
        {"session_id": "other-session", **native(base, "Edit", file_path=base / "README.md")},
        env,
    )
    print(f"{actual.upper():5} [claude] grant does not leak to another session")
    if actual != "deny":
        failures.append(f"grant leaked to another session: {actual}: {details}")
    return failures


def set_group_bypass(env: dict[str, str], group: str, value: str) -> None:
    subprocess.run(
        [str(WTG), "config", "--repo", str(base_for_env(env)), "set", f"{group}.bypass", value],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, check=False,
    )


def base_for_env(env: dict[str, str]) -> Path:
    # The probe uses a single base repo created in the temp dir.
    return Path(env["WTG_STATE_FILE"]).parent / "repo"


def notification_failures(path: Path) -> list[str]:
    records = read_jsonl(path)
    print(f"NOTIFY auto-granted base access requests: {len(records)} notices")
    if len(records) != 1 or records[0].get("session_id") != "granted-session":
        return [f"expected one notice for the granted request, got {records}"]
    if "requested and was auto-granted" not in str(records[0].get("message")):
        return ["notification does not explain that the agent requested the grant"]
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
        body = json.loads(result.stdout)
    except json.JSONDecodeError:
        return "error", result.stdout
    if not isinstance(body, dict):
        return "error", result.stdout
    output = body.get("hookSpecificOutput") if isinstance(body.get("hookSpecificOutput"), dict) else {}
    if event == "permission-request":
        return output.get("decision", {}).get("behavior", "allow"), result.stdout
    actual, contract_error = denial_decision(harness, body)
    if contract_error:
        return "error", f"{contract_error}: {result.stdout}"
    return actual, result.stdout


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

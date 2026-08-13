#!/usr/bin/env python3
"""Exercise WorktreeGuard through a real, disposable ``codex exec`` session."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROBE_BRANCH = "wtg-codex-exec-probe"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expect", choices=("blocked", "executed"), default="blocked")
    parser.add_argument("--wtg-bin", default=str(ROOT / "bin" / "wtg"))
    parser.add_argument("--codex-bin", default=shutil.which("codex") or "codex")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="wtg-codex-exec-") as raw_temp:
        temp = Path(raw_temp).resolve()
        repo = temp / "repo"
        state = temp / "state"
        state.mkdir()
        initialize_repo(repo)

        env = {
            **os.environ,
            "WTG_BIN": str(Path(args.wtg_bin).expanduser().resolve()),
            "WTG_STATE_FILE": str(state / "state.json"),
            "WTG_DENY_LOG_FILE": str(state / "denials.jsonl"),
            "WTG_REQUEST_LOG_FILE": str(state / "requests.jsonl"),
            "WTG_NOTIFICATION_LOG_FILE": str(state / "notifications.jsonl"),
        }
        result = subprocess.run(
            [
                args.codex_bin,
                "exec",
                "--ephemeral",
                "--json",
                "--dangerously-bypass-approvals-and-sandbox",
                "-C",
                str(repo),
                (
                    f"Use the shell exactly once to run: git switch -c {PROBE_BRANCH}. "
                    "Do not use any other tool or command. Then report whether it executed."
                ),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            timeout=180,
            check=False,
        )
        events = parse_events(result.stdout)
        branch = run(["git", "branch", "--show-current"], cwd=repo).strip()
        denials = read_jsonl(state / "denials.jsonl")
        command_items = [
            event["item"]
            for event in events
            if event.get("type") == "item.completed"
            and isinstance(event.get("item"), dict)
            and event["item"].get("type") == "command_execution"
        ]
        was_blocked = (
            "Command blocked by PreToolUse hook" in result.stderr
            or any(
                "blocked by PreToolUse hook" in str(item.get("aggregated_output", ""))
                for item in command_items
            )
        )
        executed = branch == PROBE_BRANCH

        print(f"codex_exit={result.returncode}")
        print(f"branch={branch}")
        print(f"denials={len(denials)}")
        print(f"blocked_event={str(was_blocked).lower()}")
        print(f"command_executed={str(executed).lower()}")

        expected_executed = args.expect == "executed"
        valid = (
            result.returncode == 0
            and len(denials) == 1
            and executed == expected_executed
            and was_blocked != expected_executed
        )
        if valid:
            print(f"PASS codex exec command was {args.expect}")
            return 0
        print(result.stderr.strip())
        print(result.stdout.strip())
        return 1


def initialize_repo(repo: Path) -> None:
    run(["git", "init", "-q", "-b", "main", str(repo)])
    run(["git", "config", "user.email", "probe@example.com"], cwd=repo)
    run(["git", "config", "user.name", "Probe"], cwd=repo)
    (repo / "README.md").write_text("probe\n", encoding="utf-8")
    run(["git", "add", "README.md"], cwd=repo)
    run(["git", "commit", "-q", "-m", "initial"], cwd=repo)


def parse_events(raw: str) -> list[dict[str, object]]:
    events: list[dict[str, object]] = []
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


def read_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def run(command: list[str], *, cwd: Path | None = None) -> str:
    return subprocess.run(
        command, cwd=cwd, check=True, text=True, stdout=subprocess.PIPE
    ).stdout


if __name__ == "__main__":
    raise SystemExit(main())

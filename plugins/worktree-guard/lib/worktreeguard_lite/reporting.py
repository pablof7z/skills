"""Human and JSON presentation for WorktreeGuard audit logs."""

from __future__ import annotations

import json
import sys
import time
from collections import Counter
from typing import Any

from .core import (
    ANSI_BLUE,
    ANSI_BOLD,
    ANSI_CYAN,
    ANSI_DIM,
    ANSI_GREEN,
    ANSI_MAGENTA,
    ANSI_RED,
    ANSI_RESET,
    ANSI_YELLOW,
)
from .storage import action_log_path, deny_log_path


def filter_action_records(
    records: list[dict[str, Any]],
    *,
    repo_filter: str,
    session_filter: str,
    decision_filter: str,
) -> list[dict[str, Any]]:
    result = records
    if repo_filter:
        result = [record for record in result if record.get("base_path") == repo_filter]
    if session_filter:
        result = [record for record in result if record.get("session_id") == session_filter]
    if decision_filter:
        result = [record for record in result if record.get("decision") == decision_filter]
    return result


def filter_denial_records(
    records: list[dict[str, Any]],
    repo_filter: str,
    session_filter: str,
) -> list[dict[str, Any]]:
    result = records
    if repo_filter:
        result = [record for record in result if record.get("base_path") == repo_filter]
    if session_filter:
        result = [record for record in result if record.get("session_id") == session_filter]
    return result


def color_enabled(args: argparse.Namespace) -> bool:
    if args.no_color or args.color == "never":
        return False
    if args.color == "always":
        return True
    return sys.stdout.isatty()


def print_action_summary(
    records: list[dict[str, Any]],
    tail_records: list[dict[str, Any]],
    *,
    use_color: bool,
) -> None:
    print(f"{paint('action log:', ANSI_BOLD, use_color)} {paint(str(action_log_path()), ANSI_CYAN, use_color)}")
    print(f"{paint('total actions:', ANSI_BOLD, use_color)} {paint(str(len(records)), ANSI_BLUE, use_color)}")
    print(paint("by decision:", ANSI_BOLD, use_color))
    for decision, count in Counter(str(record.get("decision") or "") for record in records).most_common():
        color = action_decision_color(decision)
        print(f"  {paint(f'{count:>4}', color, use_color)}  {paint(decision, color, use_color)}")
    print(paint("by reason:", ANSI_BOLD, use_color))
    for reason, count in Counter(str(record.get("reason") or "") for record in records).most_common(10):
        print(f"  {paint(f'{count:>4}', ANSI_BLUE, use_color)}  {paint(reason, ANSI_YELLOW, use_color)}")
    print(paint("by command:", ANSI_BOLD, use_color))
    for command, count in Counter(action_record_command(record) for record in records).most_common(10):
        print(f"  {paint(f'{count:>4}', ANSI_BLUE, use_color)}  {paint(command, ANSI_YELLOW, use_color)}")
    print(paint(f"tail ({len(tail_records)}):", ANSI_BOLD, use_color))
    for record in tail_records:
        print(format_action_record(record, use_color=use_color))


def print_denial_summary(
    records: list[dict[str, Any]],
    tail_records: list[dict[str, Any]],
    *,
    use_color: bool,
) -> None:
    print(f"{paint('deny log:', ANSI_BOLD, use_color)} {paint(str(deny_log_path()), ANSI_CYAN, use_color)}")
    print(f"{paint('total denials:', ANSI_BOLD, use_color)} {paint(str(len(records)), ANSI_RED, use_color)}")
    print(paint("by repo:", ANSI_BOLD, use_color))
    for repo, count in Counter(str(record.get("base_path") or "") for record in records).most_common():
        print(f"  {paint(f'{count:>4}', ANSI_RED, use_color)}  {paint(repo, ANSI_CYAN, use_color)}")
    print(paint("by command:", ANSI_BOLD, use_color))
    for command, count in Counter(str(record.get("command") or "") for record in records).most_common(10):
        print(f"  {paint(f'{count:>4}', ANSI_RED, use_color)}  {paint(command, ANSI_YELLOW, use_color)}")
    print(paint(f"tail ({len(tail_records)}):", ANSI_BOLD, use_color))
    for record in tail_records:
        print(format_denial_record(record, use_color=use_color))


def follow_actions(
    *,
    repo_filter: str,
    session_filter: str,
    decision_filter: str,
    use_color: bool,
) -> None:
    path = action_log_path()
    print(paint("following new actions; press Ctrl-C to stop", ANSI_DIM, use_color), flush=True)
    position = path.stat().st_size if path.is_file() else 0
    try:
        while True:
            if not path.is_file():
                time.sleep(0.25)
                continue
            size = path.stat().st_size
            if size < position:
                position = 0
            if size == position:
                time.sleep(0.25)
                continue
            with path.open("r", encoding="utf-8") as handle:
                handle.seek(position)
                for line in handle:
                    record = record_from_line(line)
                    if record is not None and action_record_matches(
                        record,
                        repo_filter=repo_filter,
                        session_filter=session_filter,
                        decision_filter=decision_filter,
                    ):
                        print(format_action_record(record, use_color=use_color), flush=True)
                position = handle.tell()
    except KeyboardInterrupt:
        print(paint("stopped", ANSI_DIM, use_color))


def follow_denials(*, repo_filter: str, session_filter: str, use_color: bool) -> None:
    path = deny_log_path()
    print(paint("following new denials; press Ctrl-C to stop", ANSI_DIM, use_color), flush=True)
    position = path.stat().st_size if path.is_file() else 0
    try:
        while True:
            if not path.is_file():
                time.sleep(0.25)
                continue
            size = path.stat().st_size
            if size < position:
                position = 0
            if size == position:
                time.sleep(0.25)
                continue
            with path.open("r", encoding="utf-8") as handle:
                handle.seek(position)
                for line in handle:
                    record = denial_record_from_line(line)
                    if record is not None and denial_record_matches(record, repo_filter, session_filter):
                        print(format_denial_record(record, use_color=use_color), flush=True)
                position = handle.tell()
    except KeyboardInterrupt:
        print(paint("stopped", ANSI_DIM, use_color))


def action_record_matches(
    record: dict[str, Any],
    *,
    repo_filter: str,
    session_filter: str,
    decision_filter: str,
) -> bool:
    if repo_filter and record.get("base_path") != repo_filter:
        return False
    if session_filter and record.get("session_id") != session_filter:
        return False
    if decision_filter and record.get("decision") != decision_filter:
        return False
    return True


def denial_record_from_line(line: str) -> dict[str, Any] | None:
    return record_from_line(line)


def record_from_line(line: str) -> dict[str, Any] | None:
    if not line.strip():
        return None
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return None
    return record if isinstance(record, dict) else None


def denial_record_matches(record: dict[str, Any], repo_filter: str, session_filter: str) -> bool:
    if repo_filter and record.get("base_path") != repo_filter:
        return False
    if session_filter and record.get("session_id") != session_filter:
        return False
    return True


def format_denial_record(record: dict[str, Any], *, use_color: bool) -> str:
    timestamp = str(record.get("timestamp") or "")
    base_path = str(record.get("base_path") or "")
    effective_cwd = str(record.get("effective_cwd") or "")
    session_id = str(record.get("session_id") or "")
    command = str(record.get("command") or "")
    return (
        f"  {paint('DENY', ANSI_RED + ANSI_BOLD, use_color)} "
        f"{paint(timestamp, ANSI_DIM, use_color)} "
        f"repo={paint(base_path, ANSI_CYAN, use_color)} "
        f"cwd={paint(effective_cwd, ANSI_BLUE, use_color)} "
        f"session={paint(session_id, ANSI_MAGENTA, use_color)} "
        f"cmd={paint(command, ANSI_YELLOW, use_color)}"
    )


def format_action_record(record: dict[str, Any], *, use_color: bool) -> str:
    timestamp = str(record.get("timestamp") or "")
    decision = str(record.get("decision") or "").upper()
    reason = str(record.get("reason") or "")
    base_path = str(record.get("base_path") or "")
    effective_cwd = str(record.get("effective_cwd") or "")
    session_id = str(record.get("session_id") or "")
    command = action_record_command(record)
    color = action_decision_color(decision.lower())
    return (
        f"  {paint(decision or 'ACTION', color + ANSI_BOLD, use_color)} "
        f"{paint(timestamp, ANSI_DIM, use_color)} "
        f"reason={paint(reason, ANSI_YELLOW, use_color)} "
        f"repo={paint(base_path, ANSI_CYAN, use_color)} "
        f"cwd={paint(effective_cwd, ANSI_BLUE, use_color)} "
        f"session={paint(session_id, ANSI_MAGENTA, use_color)} "
        f"cmd={paint(command, ANSI_YELLOW, use_color)}"
    )


def action_decision_color(decision: str) -> str:
    if decision == "allow":
        return ANSI_GREEN
    if decision == "deny":
        return ANSI_RED
    if decision == "repair":
        return ANSI_CYAN
    if decision == "repair_failed":
        return ANSI_YELLOW
    return ANSI_BLUE


def action_record_command(record: dict[str, Any]) -> str:
    command = str(record.get("command") or "")
    if command:
        return command
    tool_name = str(record.get("tool_name") or "")
    return f"tool:{tool_name}" if tool_name else ""


def paint(value: str, color: str, enabled: bool) -> str:
    return f"{color}{value}{ANSI_RESET}" if enabled and value else value

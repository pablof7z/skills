"""Small local WorktreeGuard implementation bundled with the WorktreeGuard plugin."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


READ_ONLY_TOOLS = {"Read", "Glob", "Grep", "LS"}
WRITE_TOOLS = {"apply_patch", "Edit", "Write", "MultiEdit", "NotebookEdit"}
DANGEROUS_GIT_COMMANDS = {
    "checkout",
    "clean",
    "rebase",
    "reset",
    "restore",
    "switch",
}
DEFAULT_GRANT_TTL_SECONDS = 30 * 60
DEFAULT_ACTION_LOG_FILE = "worktreeguard-actions.jsonl"
DEFAULT_DENY_LOG_FILE = "worktreeguard-denied-actions.jsonl"
SHELL_CONTROL_TOKENS = {"&&", "||", ";", "|"}
ANSI_RESET = "\033[0m"
ANSI_BOLD = "\033[1m"
ANSI_DIM = "\033[2m"
ANSI_RED = "\033[31m"
ANSI_GREEN = "\033[32m"
ANSI_YELLOW = "\033[33m"
ANSI_BLUE = "\033[34m"
ANSI_MAGENTA = "\033[35m"
ANSI_CYAN = "\033[36m"


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except WorktreeGuardError as error:
        print(str(error), file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wtg")
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="Initialize local WorktreeGuard state")
    init_parser.add_argument("--repo", default=".")
    init_parser.set_defaults(func=cmd_init)

    protect_parser = subparsers.add_parser("protect", help="Protect a clean base checkout")
    protect_parser.add_argument("--repo", default=".")
    protect_parser.set_defaults(func=cmd_protect)

    status_parser = subparsers.add_parser("status", help="Show protection status")
    status_parser.add_argument("--repo", default=".")
    status_parser.set_defaults(func=cmd_status)

    current_parser = subparsers.add_parser("current", help="Show current repo context")
    current_parser.add_argument("--repo", default=".")
    current_parser.set_defaults(func=cmd_current)

    request_parser = subparsers.add_parser(
        "request-base-access",
        help="Ask the local human for temporary protected-base access",
    )
    request_parser.add_argument("--repo", default=".")
    request_parser.add_argument("--reason", required=True)
    request_parser.add_argument("--scope", default="session", choices=["once", "operation", "session"])
    request_parser.add_argument("--ttl-seconds", type=int, default=DEFAULT_GRANT_TTL_SECONDS)
    request_parser.add_argument("--wait", action="store_true")
    request_parser.add_argument("--timeout", type=int, default=0)
    request_parser.set_defaults(func=cmd_request_base_access)

    doctor_parser = subparsers.add_parser("doctor", help="Check local WorktreeGuard-lite setup")
    doctor_parser.set_defaults(func=cmd_doctor)

    actions_parser = subparsers.add_parser("actions", help="Inspect full WorktreeGuard action log")
    actions_parser.add_argument("--tail", type=int, default=20)
    actions_parser.add_argument("-f", "--follow", action="store_true", help="Follow new actions")
    actions_parser.add_argument("--repo")
    actions_parser.add_argument("--session")
    actions_parser.add_argument("--decision", choices=["allow", "deny", "repair", "repair_failed"])
    actions_parser.add_argument("--color", choices=["auto", "always", "never"], default="auto")
    actions_parser.add_argument("--no-color", action="store_true")
    actions_parser.add_argument("--json", action="store_true")
    actions_parser.set_defaults(func=cmd_actions)

    denials_parser = subparsers.add_parser("denials", help="Inspect denied action log")
    denials_parser.add_argument("--tail", type=int, default=20)
    denials_parser.add_argument("-f", "--follow", action="store_true", help="Follow new denials")
    denials_parser.add_argument("--repo")
    denials_parser.add_argument("--session")
    denials_parser.add_argument("--color", choices=["auto", "always", "never"], default="auto")
    denials_parser.add_argument("--no-color", action="store_true")
    denials_parser.add_argument("--json", action="store_true")
    denials_parser.set_defaults(func=cmd_denials)

    hook_parser = subparsers.add_parser("hook", help="Run a harness hook")
    hook_subparsers = hook_parser.add_subparsers(dest="harness", required=True)
    for harness_name in ("codex", "claude"):
        harness_parser = hook_subparsers.add_parser(harness_name)
        harness_parser.add_argument("event", nargs="?", default="hook")
        harness_parser.set_defaults(func=cmd_hook_harness)

    return parser


def cmd_init(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    state = load_state()
    state.setdefault("repos", {})
    save_state(state)
    print(f"Initialized WorktreeGuard state for {repo.base_path}")
    return 0


def cmd_protect(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    status = git(repo.base_path, "status", "--porcelain=v1", "-z").stdout
    if status:
        raise WorktreeGuardError(
            "Cannot protect this repo yet.\n\n"
            "The base checkout must be clean first:\n"
            f"  branch: {repo.branch}\n\n"
            "Commit, stash, or discard local changes, then run protect again."
        )

    state = load_state()
    repos = state.setdefault("repos", {})
    repos[str(repo.base_path)] = {
        "base_path": str(repo.base_path),
        "common_git_dir": str(repo.common_git_dir),
        "branch": repo.branch,
        "head": repo.head,
        "protected_at": int(time.time()),
    }
    save_state(state)
    print(f"Protected base checkout: {repo.base_path}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    protected = protected_repo_for_path(repo.base_path)
    if protected is None:
        print(f"Not protected: {repo.base_path}")
        return 1
    print(f"Protected: {protected['base_path']}")
    print(f"Branch: {protected.get('branch', repo.branch)}")
    print(f"HEAD: {protected.get('head', repo.head)}")
    return 0


def cmd_current(args: argparse.Namespace) -> int:
    path = resolve_path(args.repo)
    repo = discover_repo(path)
    protected = protected_repo_for_path(path)
    payload = {
        "cwd": str(path),
        "repo": str(repo.base_path),
        "protected": protected is not None and path_contains(resolve_path(str(protected["base_path"])), path),
        "worktree": not path_contains(repo.base_path, path),
    }
    print(json.dumps(payload, indent=2))
    return 0


def cmd_request_base_access(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    protected = protected_repo_for_path(repo.base_path)
    if protected is None:
        raise WorktreeGuardError(
            "Base access grants only apply to Git main worktrees."
        )

    base_path = resolve_path(str(protected["base_path"]))
    decision = request_human_approval(
        repo=repo,
        reason=args.reason,
        requested_scope=args.scope,
        timeout=args.timeout,
    )
    if decision is None:
        print(
            "Denied. Continue from a Git worktree instead.",
            file=sys.stderr,
        )
        return 1

    grant = create_grant(
        base_path=base_path,
        scope=decision,
        reason=args.reason,
        ttl_seconds=args.ttl_seconds,
    )
    print(f"Approved until {time.strftime('%Y-%m-%dT%H:%M:%S%z', time.localtime(grant['expires_at']))}.")
    print("Retry the previous operation.")
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    git_path = shutil.which("git")
    print(f"git: {git_path or 'missing'}")
    print(f"state: {state_path()}")
    print(f"action log: {action_log_path()}")
    print(f"deny log: {deny_log_path()}")
    for harness_name in ("codex", "claude"):
        hook_shim = stable_hook_shim_path(harness_name)
        status = "executable" if os.access(hook_shim, os.X_OK) else "missing"
        print(f"hook shim ({harness_name}): {hook_shim} ({status})")
    state = load_state()
    repos = state.get("repos", {})
    grants = active_grants(state)
    print(f"protected repos: {len(repos)}")
    for repo in repos.values():
        print(f"- {repo.get('base_path')}")
    print(f"active grants: {len(grants)}")
    return 0 if git_path else 1


def cmd_actions(args: argparse.Namespace) -> int:
    if args.follow and args.json:
        raise WorktreeGuardError("`wtg actions --json` cannot be combined with `--follow`.")

    repo_filter = str(resolve_path(args.repo)) if args.repo else ""
    session_filter = str(args.session or "")
    decision_filter = str(args.decision or "")
    records = filter_action_records(
        read_action_records(),
        repo_filter=repo_filter,
        session_filter=session_filter,
        decision_filter=decision_filter,
    )

    tail_count = max(0, args.tail)
    tail_records = records[-tail_count:] if tail_count else []
    if args.json:
        emit(
            {
                "log": str(action_log_path()),
                "total": len(records),
                "by_decision": dict(Counter(str(record.get("decision") or "") for record in records)),
                "by_reason": dict(Counter(str(record.get("reason") or "") for record in records)),
                "by_repo": dict(Counter(str(record.get("base_path") or "") for record in records)),
                "by_session": dict(Counter(str(record.get("session_id") or "") for record in records)),
                "by_command": dict(Counter(str(record.get("command") or "") for record in records)),
                "tail": tail_records,
            }
        )
        return 0

    use_color = color_enabled(args)
    print_action_summary(records, tail_records, use_color=use_color)
    if args.follow:
        follow_actions(
            repo_filter=repo_filter,
            session_filter=session_filter,
            decision_filter=decision_filter,
            use_color=use_color,
        )
    return 0


def cmd_denials(args: argparse.Namespace) -> int:
    if args.follow and args.json:
        raise WorktreeGuardError("`wtg denials --json` cannot be combined with `--follow`.")

    repo_filter = str(resolve_path(args.repo)) if args.repo else ""
    session_filter = str(args.session or "")
    records = filter_denial_records(read_denial_records(), repo_filter, session_filter)

    tail_count = max(0, args.tail)
    tail_records = records[-tail_count:] if tail_count else []
    if args.json:
        emit(
            {
                "log": str(deny_log_path()),
                "total": len(records),
                "by_repo": dict(Counter(str(record.get("base_path") or "") for record in records)),
                "by_session": dict(Counter(str(record.get("session_id") or "") for record in records)),
                "by_command": dict(Counter(str(record.get("command") or "") for record in records)),
                "tail": tail_records,
            }
        )
        return 0

    use_color = color_enabled(args)
    print_denial_summary(records, tail_records, use_color=use_color)
    if args.follow:
        follow_denials(repo_filter=repo_filter, session_filter=session_filter, use_color=use_color)
    return 0


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


def cmd_hook_harness(args: argparse.Namespace) -> int:
    payload = load_hook_payload(sys.stdin.buffer.read())
    return run_harness_hook(args.event, payload)


def run_harness_hook(event: str, payload: dict[str, Any]) -> int:
    if event == "session-start":
        return emit_session_context(payload)

    if event == "post-tool-use":
        record_session_cwd(payload)
        return 0

    if event == "stop":
        clear_session_cwd(payload)
        return 0

    if event not in {"pre-tool-use", "permission-request"}:
        return 0

    payload_cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    session_cwd = stored_session_cwd(payload) or payload_cwd
    operation = extract_operation(payload)
    cwd = effective_operation_cwd(operation, session_cwd)
    repair_protected_base_branches(event=event, payload=payload, operation=operation, cwd=cwd)

    write_target = protected_write_target(operation, cwd)
    if write_target is not None:
        base_path, protected = write_target
        if has_valid_grant(base_path):
            log_action(
                event=event,
                payload=payload,
                base_path=base_path,
                cwd=cwd,
                operation=operation,
                decision="allow",
                reason="grant_allowed",
                protected=protected,
            )
            return 0
        return deny_operation(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            protected=protected,
        )

    protected = protected_repo_for_path(cwd)
    if protected is None:
        log_action(
            event=event,
            payload=payload,
            base_path=None,
            cwd=cwd,
            operation=operation,
            decision="allow",
            reason="unprotected",
        )
        return 0

    base_path = resolve_path(str(protected["base_path"]))
    if not path_contains(base_path, cwd):
        log_action(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            decision="allow",
            reason="worktree_allowed",
            protected=protected,
        )
        return 0

    if operation_is_allowed(operation, cwd):
        log_action(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            decision="allow",
            reason="policy_allowed",
            protected=protected,
        )
        return 0

    if has_valid_grant(base_path):
        log_action(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            decision="allow",
            reason="grant_allowed",
            protected=protected,
        )
        return 0

    return deny_operation(
        event=event,
        payload=payload,
        base_path=base_path,
        cwd=cwd,
        operation=operation,
        protected=protected,
    )


def deny_operation(
    *,
    event: str,
    payload: dict[str, Any],
    base_path: Path,
    cwd: Path,
    operation: dict[str, Any],
    protected: dict[str, Any] | None,
) -> int:
    message = denial_message(base_path)
    record = action_record(
        event=event,
        payload=payload,
        base_path=base_path,
        cwd=cwd,
        operation=operation,
        decision="deny",
        reason="protected_base_mutation",
        protected=protected,
    )
    write_action_log(record)
    write_denial_log(record)
    if event == "permission-request":
        emit(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "deny", "message": message},
                }
            }
        )
    else:
        emit(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": message,
                }
            }
        )
    return 0


def emit_session_context(payload: dict[str, Any]) -> int:
    cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    protected = protected_repo_for_path(cwd)
    if protected is not None:
        base_path = resolve_path(str(protected["base_path"]))
        context = (
            "WorktreeGuard is active for this protected base checkout:\n"
            f"{base_path}\n\n"
            "Do mutating work from a Git worktree, not this protected base checkout."
        )
    else:
        try:
            repo = discover_repo(cwd)
        except WorktreeGuardError:
            context = "WorktreeGuard is installed. This directory is not in a Git repo."
        else:
            context = (
                "WorktreeGuard is active. This directory is a Git worktree for "
                "the protected base checkout:\n"
                f"{repo.base_path}\n\n"
                "Mutating work is allowed in this worktree."
            )
    emit({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}})
    return 0


def protected_repo_for_path(path: Path) -> dict[str, Any] | None:
    path = resolve_path(path)
    env_base = os.environ.get("WTG_PROTECTED_BASE")
    if env_base:
        base = resolve_path(env_base)
        if path_contains(base, path) and git_main_worktree_matches(base, path):
            return {
                "base_path": str(base),
            }

    env_worktree = os.environ.get("WTG_WORKTREE_PATH")
    if env_worktree and path_contains(resolve_path(env_worktree), path):
        return None

    state = load_state()
    for repo in state.get("repos", {}).values():
        protected = validated_protected_repo(repo, path)
        if protected is not None:
            return protected

    try:
        repo = discover_repo(path)
    except WorktreeGuardError:
        return None
    marker = repo.base_path / ".wtg.toml"
    if marker.is_file() and repo.worktree_path == repo.base_path and path_contains(repo.base_path, path):
        return {
            "base_path": str(repo.base_path),
            "common_git_dir": str(repo.common_git_dir),
            "branch": repo.branch,
            "head": repo.head,
        }
    if repo.worktree_path == repo.base_path and path_contains(repo.base_path, path):
        return {
            "base_path": str(repo.base_path),
            "common_git_dir": str(repo.common_git_dir),
            "branch": repo.branch,
            "head": repo.head,
            "default_protected": True,
        }
    return None


def extract_operation(payload: dict[str, Any]) -> dict[str, Any]:
    event = payload.get("event") if isinstance(payload.get("event"), dict) else {}
    tool = payload.get("tool") if isinstance(payload.get("tool"), dict) else {}
    tool_name = (
        payload.get("tool_name")
        or event.get("tool_name")
        or tool.get("name")
        or payload.get("tool")
        or ""
    )
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = tool.get("input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    command = tool_input.get("command") or tool_input.get("cmd") or payload.get("command") or ""
    return {"tool_name": str(tool_name), "command": str(command), "tool_input": tool_input}


def effective_operation_cwd(operation: dict[str, Any], fallback: Path) -> Path:
    cwd = fallback
    tool_input = operation.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("workdir", "cwd", "working_directory", "directory"):
            raw_value = tool_input.get(key)
            if not isinstance(raw_value, str) or not raw_value.strip():
                continue
            candidate = Path(raw_value).expanduser()
            if not candidate.is_absolute():
                candidate = fallback / candidate
            cwd = resolve_path(candidate)
            break

    command_cwd = git_command_cwd(operation.get("command", ""), cwd)
    return command_cwd or cwd


def record_session_cwd(payload: dict[str, Any]) -> None:
    session_id = session_id_from_payload(payload)
    if not session_id:
        return
    payload_cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    previous_cwd = stored_session_cwd(payload) or payload_cwd
    operation = extract_operation(payload)
    next_cwd = cwd_from_pwd_response(operation, payload)
    if next_cwd is None:
        next_cwd = cwd_from_git_worktree_add(operation, previous_cwd)
    if next_cwd is None:
        return

    state = load_state()
    sessions = state.setdefault("sessions", {})
    if not isinstance(sessions, dict):
        sessions = {}
        state["sessions"] = sessions
    sessions[session_id] = {
        "cwd": str(next_cwd),
        "updated_at": int(time.time()),
    }
    save_state(state)


def clear_session_cwd(payload: dict[str, Any]) -> None:
    session_id = session_id_from_payload(payload)
    if not session_id:
        return
    state = load_state()
    sessions = state.get("sessions")
    if not isinstance(sessions, dict) or session_id not in sessions:
        return
    del sessions[session_id]
    save_state(state)


def stored_session_cwd(payload: dict[str, Any]) -> Path | None:
    session_id = session_id_from_payload(payload)
    if not session_id:
        return None
    state = load_state()
    sessions = state.get("sessions")
    if not isinstance(sessions, dict):
        return None
    session = sessions.get(session_id)
    if not isinstance(session, dict):
        return None
    raw_cwd = session.get("cwd")
    if not isinstance(raw_cwd, str) or not raw_cwd:
        return None
    return resolve_path(raw_cwd)


def session_id_from_payload(payload: dict[str, Any]) -> str:
    raw_session_id = (
        payload.get("session_id")
        or payload.get("sessionId")
        or payload.get("conversation_id")
        or payload.get("conversationId")
        or payload.get("thread_id")
        or payload.get("threadId")
    )
    return str(raw_session_id) if raw_session_id else ""


def cwd_from_pwd_response(operation: dict[str, Any], payload: dict[str, Any]) -> Path | None:
    command = operation.get("command")
    if not isinstance(command, str):
        return None
    try:
        parts = shlex.split(command.strip())
    except ValueError:
        return None
    if parts != ["pwd"]:
        return None
    response = payload.get("tool_response")
    if not isinstance(response, str):
        return None
    lines = [line.strip() for line in response.splitlines() if line.strip()]
    if len(lines) != 1:
        return None
    path = resolve_path(lines[0])
    return path if path.is_dir() else None


def cwd_from_git_worktree_add(operation: dict[str, Any], fallback: Path) -> Path | None:
    command = operation.get("command")
    if not isinstance(command, str):
        return None
    try:
        parts = shlex.split(command.strip())
    except ValueError:
        return None
    if not parts or Path(parts[0]).name != "git":
        return None
    git_cwd, git_args = git_effective_cwd(parts[1:], fallback)
    if len(git_args) < 2 or git_args[0] != "worktree" or git_args[1] != "add":
        return None
    target = git_worktree_add_path(git_args[2:])
    if target is None:
        return None
    target_path = resolve_path(target if target.is_absolute() else git_cwd / target)
    if not target_path.is_dir():
        return None
    protected = protected_repo_for_path(git_cwd)
    if protected is not None and path_contains(resolve_path(str(protected["base_path"])), target_path):
        return None
    return target_path


def git_command_cwd(command: Any, cwd: Path) -> Path | None:
    if not isinstance(command, str) or not command.strip():
        return None
    try:
        parts = shlex.split(command.strip())
    except ValueError:
        return None
    if not parts or Path(parts[0]).name != "git":
        return None
    git_cwd, _ = git_effective_cwd(parts[1:], cwd)
    return git_cwd


def operation_is_allowed(operation: dict[str, Any], cwd: Path) -> bool:
    tool_name = operation["tool_name"]
    command = operation["command"]
    normalized_tool_name = normalize_tool_name(tool_name)
    if tool_name in READ_ONLY_TOOLS or normalized_tool_name in {"read", "glob", "grep", "ls", "list"}:
        return True
    if operation_is_write_tool(operation):
        return write_operation_targets_allowed(operation, cwd)
    if tool_name.startswith("mcp__"):
        lowered = tool_name.lower()
        return any(token in lowered for token in ("read", "list", "search", "grep", "glob"))
    if tool_name in {"Bash", "Shell"} or command:
        return shell_command_is_read_only_or_control(command, cwd)
    return False


def operation_is_write_tool(operation: dict[str, Any]) -> bool:
    tool_name = operation["tool_name"]
    normalized_tool_name = normalize_tool_name(tool_name)
    return tool_name in WRITE_TOOLS or normalized_tool_name in {
        "applypatch",
        "edit",
        "write",
        "multiedit",
        "notebookedit",
    }


def protected_write_target(operation: dict[str, Any], cwd: Path) -> tuple[Path, dict[str, Any]] | None:
    if not operation_is_write_tool(operation):
        return None
    for target in write_operation_target_paths(operation, cwd):
        context = existing_context_dir(target)
        protected = protected_repo_for_path(context)
        if protected is None:
            continue
        base_path = resolve_path(str(protected["base_path"]))
        if path_contains(base_path, target) and git_main_worktree_matches(base_path, context):
            return base_path, protected
    return None


def write_operation_targets_allowed(operation: dict[str, Any], cwd: Path) -> bool:
    targets = write_operation_target_paths(operation, cwd)
    if not targets:
        return False
    return not any(path_is_protected_main_worktree_target(target) for target in targets)


def write_operation_target_paths(operation: dict[str, Any], cwd: Path) -> list[Path]:
    targets: list[Path] = []
    tool_input = operation.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("file_path", "filepath", "path", "filename", "notebook_path"):
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                targets.append(resolve_operation_path(value, cwd))
    command = operation.get("command")
    if isinstance(command, str):
        targets.extend(apply_patch_target_paths(command, cwd))
    return unique_paths(targets)


def apply_patch_target_paths(command: str, cwd: Path) -> list[Path]:
    prefixes = (
        "*** Add File: ",
        "*** Delete File: ",
        "*** Update File: ",
        "*** Move to: ",
    )
    targets: list[Path] = []
    for line in command.splitlines():
        for prefix in prefixes:
            if line.startswith(prefix):
                raw_path = line.removeprefix(prefix).strip()
                if raw_path:
                    targets.append(resolve_operation_path(raw_path, cwd))
                break
    return targets


def resolve_operation_path(value: str, cwd: Path) -> Path:
    raw_path = Path(os.path.expandvars(value)).expanduser()
    return resolve_path(raw_path if raw_path.is_absolute() else cwd / raw_path)


def unique_paths(paths: list[Path]) -> list[Path]:
    seen: set[Path] = set()
    result: list[Path] = []
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        result.append(path)
    return result


def path_is_protected_main_worktree_target(path: Path) -> bool:
    context = existing_context_dir(path)
    protected = protected_repo_for_path(context)
    if protected is None:
        return False
    base_path = resolve_path(str(protected["base_path"]))
    return path_contains(base_path, path) and git_main_worktree_matches(base_path, context)


def existing_context_dir(path: Path) -> Path:
    candidate = path if path.is_dir() else path.parent
    while not candidate.exists() and candidate != candidate.parent:
        candidate = candidate.parent
    return candidate


def shell_command_is_read_only_or_control(command: str, cwd: Path) -> bool:
    stripped = command.strip()
    if not stripped:
        return True
    try:
        parts = shell_tokens(stripped)
    except ValueError:
        return False
    if not parts:
        return True
    current_cwd = cwd
    for segment, separator in shell_segments(parts):
        if shell_segment_has_dangerous_git(segment, current_cwd):
            return False
        next_cwd = shell_segment_cd_cwd(segment, current_cwd)
        if next_cwd is not None and separator in {None, ";", "&&"}:
            current_cwd = next_cwd
    return True


def shell_tokens(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def shell_segments(parts: list[str]) -> list[tuple[list[str], str | None]]:
    segments: list[tuple[list[str], str | None]] = []
    current: list[str] = []
    for part in parts:
        if part in SHELL_CONTROL_TOKENS:
            if current:
                segments.append((current, part))
                current = []
            continue
        current.append(part)
    if current:
        segments.append((current, None))
    return segments


def shell_segment_has_dangerous_git(parts: list[str], cwd: Path) -> bool:
    while parts and shell_assignment_is_prefix(parts[0]):
        parts = parts[1:]
    if not parts:
        return False
    executable = Path(parts[0]).name
    if executable in {"command", "builtin"}:
        if len(parts) >= 2 and parts[1] == "-v":
            return False
        return shell_segment_has_dangerous_git(parts[1:], cwd)
    if executable in {"env", "sudo", "time"}:
        return shell_segment_has_dangerous_git(shell_wrapper_payload(parts[1:]), cwd)
    if executable in {"bash", "sh", "zsh"}:
        payload = shell_interpreter_payload(parts[1:])
        if payload is None:
            return False
        return not shell_command_is_read_only_or_control(payload, cwd)
    if executable == "git":
        git_cwd, git_args = git_effective_cwd(parts[1:], cwd)
        protected = protected_repo_for_path(git_cwd)
        if protected is None:
            return False
        base_path = resolve_path(str(protected["base_path"]))
        if not path_contains(base_path, git_cwd) or not git_main_worktree_matches(base_path, git_cwd):
            return False
        return not git_command_is_allowed_in_base(git_args, git_cwd)
    return False


def shell_interpreter_payload(args: list[str]) -> str | None:
    remaining = list(args)
    while remaining and shell_assignment_is_prefix(remaining[0]):
        remaining = remaining[1:]
    index = 0
    while index < len(remaining):
        arg = remaining[index]
        if arg == "--":
            index += 1
            continue
        if arg == "-c" or (arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]):
            return remaining[index + 1] if index + 1 < len(remaining) else ""
        if arg.startswith("-"):
            index += 1
            continue
        return None
    return None


def shell_segment_cd_cwd(parts: list[str], cwd: Path) -> Path | None:
    while parts and shell_assignment_is_prefix(parts[0]):
        parts = parts[1:]
    if not parts:
        return None
    executable = Path(parts[0]).name
    offset = 1
    if executable == "builtin" and len(parts) >= 2 and parts[1] == "cd":
        offset = 2
    elif executable != "cd":
        return None
    if len(parts) <= offset:
        return Path.home()
    target = parts[offset]
    if target == "-":
        return None
    raw_path = Path(os.path.expandvars(target)).expanduser()
    candidate = raw_path if raw_path.is_absolute() else cwd / raw_path
    resolved = resolve_path(candidate)
    return resolved if resolved.is_dir() else None


def shell_assignment_is_prefix(part: str) -> bool:
    if "=" not in part:
        return False
    name, _, _ = part.partition("=")
    return bool(name) and (name[0].isalpha() or name[0] == "_") and all(
        character.isalnum() or character == "_" for character in name
    )


def shell_wrapper_payload(args: list[str]) -> list[str]:
    remaining = list(args)
    while remaining and shell_assignment_is_prefix(remaining[0]):
        remaining = remaining[1:]
    while remaining and remaining[0].startswith("-"):
        remaining = remaining[1:]
    while remaining and shell_assignment_is_prefix(remaining[0]):
        remaining = remaining[1:]
    return remaining


def git_command_is_allowed_in_base(args: list[str], cwd: Path) -> bool:
    if not args:
        return True
    return args[0] not in DANGEROUS_GIT_COMMANDS


def git_effective_cwd(args: list[str], cwd: Path) -> tuple[Path, list[str]]:
    remaining = list(args)
    effective_cwd = cwd
    while remaining:
        arg = remaining[0]
        if arg == "-C":
            if len(remaining) < 2:
                return effective_cwd, remaining
            raw_path = Path(remaining[1]).expanduser()
            effective_cwd = resolve_path(raw_path if raw_path.is_absolute() else effective_cwd / raw_path)
            remaining = remaining[2:]
            continue
        if arg.startswith("-C") and len(arg) > 2:
            raw_path = Path(arg[2:]).expanduser()
            effective_cwd = resolve_path(raw_path if raw_path.is_absolute() else effective_cwd / raw_path)
            remaining = remaining[1:]
            continue
        if arg == "--work-tree":
            if len(remaining) < 2:
                return effective_cwd, remaining
            raw_path = Path(remaining[1]).expanduser()
            effective_cwd = resolve_path(raw_path if raw_path.is_absolute() else effective_cwd / raw_path)
            remaining = remaining[2:]
            continue
        if arg.startswith("--work-tree="):
            raw_path = Path(arg.partition("=")[2]).expanduser()
            effective_cwd = resolve_path(raw_path if raw_path.is_absolute() else effective_cwd / raw_path)
            remaining = remaining[1:]
            continue
        if arg in {"-c", "--config-env", "--exec-path", "--git-dir", "--namespace"}:
            if len(remaining) < 2:
                return effective_cwd, remaining
            remaining = remaining[2:]
            continue
        if any(arg.startswith(f"{option}=") for option in ("--config-env", "--exec-path", "--git-dir", "--namespace")):
            remaining = remaining[1:]
            continue
        if arg in {"--no-pager", "--paginate", "--bare", "--version", "--help", "--no-optional-locks"}:
            remaining = remaining[1:]
            continue
        break
    return effective_cwd, remaining


def git_worktree_add_path(args: list[str]) -> Path | None:
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"-b", "-B", "--reason"}:
            index += 2
            continue
        if arg.startswith(("-b", "-B")) and len(arg) > 2:
            index += 1
            continue
        if arg.startswith("--reason="):
            index += 1
            continue
        if arg.startswith("-") and arg != "-":
            index += 1
            continue
        return Path(arg)
    return None


def normalize_tool_name(tool_name: str) -> str:
    return tool_name.replace("_", "").replace("-", "").lower()


def validated_protected_repo(repo: Any, path: Path) -> dict[str, Any] | None:
    if not isinstance(repo, dict):
        return None
    raw_base_path = repo.get("base_path")
    if not isinstance(raw_base_path, str) or not raw_base_path:
        return None
    base_path = resolve_path(raw_base_path)
    if not path_contains(base_path, path):
        return None
    if not git_main_worktree_matches(base_path, path):
        return None
    protected = dict(repo)
    protected["base_path"] = str(base_path)
    return protected


def git_main_worktree_matches(base_path: Path, path: Path) -> bool:
    try:
        repo = discover_repo(path)
    except WorktreeGuardError:
        return False
    return repo.base_path == base_path and repo.worktree_path == base_path


def repair_protected_base_branches(
    *,
    event: str,
    payload: dict[str, Any],
    operation: dict[str, Any],
    cwd: Path,
) -> None:
    seen: set[Path] = set()
    state = load_state()
    for repo in state.get("repos", {}).values():
        if not isinstance(repo, dict):
            continue
        raw_base_path = repo.get("base_path")
        if not isinstance(raw_base_path, str) or not raw_base_path:
            continue
        base_path = resolve_path(raw_base_path)
        if base_path in seen:
            continue
        seen.add(base_path)
        repair_protected_base_branch(
            event=event,
            payload=payload,
            operation=operation,
            base_path=base_path,
            protected=repo,
        )

    protected = protected_repo_for_path(cwd)
    if protected is None:
        return
    raw_base_path = protected.get("base_path")
    if not isinstance(raw_base_path, str) or not raw_base_path:
        return
    base_path = resolve_path(raw_base_path)
    if base_path in seen:
        return
    repair_protected_base_branch(
        event=event,
        payload=payload,
        operation=operation,
        base_path=base_path,
        protected=protected,
    )


def repair_protected_base_branch(
    *,
    event: str,
    payload: dict[str, Any],
    operation: dict[str, Any],
    base_path: Path,
    protected: dict[str, Any],
) -> None:
    if not base_path.is_dir():
        return

    target_branch = default_branch_for_base(base_path, protected)
    current_branch = git_output_optional(base_path, "branch", "--show-current")
    if target_branch is None:
        log_branch_repair(
            event=event,
            payload=payload,
            operation=operation,
            base_path=base_path,
            protected=protected,
            decision="repair_failed",
            reason="base_branch_default_unknown",
            current_branch=current_branch,
            target_branch="",
        )
        return
    if current_branch == target_branch:
        return
    if not git_status_is_clean(base_path):
        log_branch_repair(
            event=event,
            payload=payload,
            operation=operation,
            base_path=base_path,
            protected=protected,
            decision="repair_failed",
            reason="base_branch_dirty",
            current_branch=current_branch,
            target_branch=target_branch,
        )
        return

    result = subprocess.run(
        ["git", "switch", target_branch],
        cwd=str(base_path),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        log_branch_repair(
            event=event,
            payload=payload,
            operation=operation,
            base_path=base_path,
            protected=protected,
            decision="repair",
            reason="base_branch_restored",
            current_branch=current_branch,
            target_branch=target_branch,
        )
        return

    log_branch_repair(
        event=event,
        payload=payload,
        operation=operation,
        base_path=base_path,
        protected=protected,
        decision="repair_failed",
        reason="base_branch_switch_failed",
        current_branch=current_branch,
        target_branch=target_branch,
        error=(result.stderr.strip() or result.stdout.strip()),
    )


def default_branch_for_base(base_path: Path, protected: dict[str, Any]) -> str | None:
    remotes = ["origin"]
    remote_output = git_output_optional(base_path, "remote")
    for remote in remote_output.splitlines():
        remote = remote.strip()
        if remote and remote not in remotes:
            remotes.append(remote)
    for remote in remotes:
        raw = git_output_optional(base_path, "symbolic-ref", "--quiet", "--short", f"refs/remotes/{remote}/HEAD")
        prefix = f"{remote}/"
        if raw.startswith(prefix):
            return raw.removeprefix(prefix)

    protected_branch = str(protected.get("branch") or "")
    if protected_branch and protected_branch != "HEAD":
        return protected_branch

    for branch in ("main", "master"):
        if local_branch_exists(base_path, branch):
            return branch
    return None


def local_branch_exists(base_path: Path, branch: str) -> bool:
    result = subprocess.run(
        ["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        cwd=str(base_path),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    return result.returncode == 0


def git_status_is_clean(base_path: Path) -> bool:
    result = subprocess.run(
        ["git", "status", "--porcelain=v1", "-z"],
        cwd=str(base_path),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=False,
        check=False,
    )
    return result.returncode == 0 and result.stdout == b""


def git_output_optional(base_path: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=str(base_path),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def log_branch_repair(
    *,
    event: str,
    payload: dict[str, Any],
    operation: dict[str, Any],
    base_path: Path,
    protected: dict[str, Any],
    decision: str,
    reason: str,
    current_branch: str,
    target_branch: str,
    error: str = "",
) -> None:
    write_action_log(
        action_record(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=base_path,
            operation=operation,
            decision=decision,
            reason=reason,
            protected=protected,
            extra={
                "current_branch": current_branch,
                "target_branch": target_branch,
                "error": error,
            },
        )
    )


def denial_message(base_path: Path) -> str:
    command = command_name()
    return (
        "Denied by WorktreeGuard.\n\n"
        "You are in the protected base checkout:\n"
        f"{base_path}\n\n"
        "This session may read this checkout, but may not edit files, switch "
        "branches, or mutate the protected checkout state here.\n\n"
        "Continue from a Git worktree instead. Use the repository's normal "
        "worktree workflow; WorktreeGuard will allow mutations outside this "
        "protected base checkout.\n\n"
        "If base access is truly required, ask for a human approval:\n\n"
        f"  {command} request-base-access --repo {shlex.quote(str(base_path))} \\\n"
        "    --reason \"<why this cannot be done in a worktree>\" \\\n"
        "    --scope session"
    )


def log_action(
    *,
    event: str,
    payload: dict[str, Any],
    base_path: Path | None,
    cwd: Path,
    operation: dict[str, Any],
    decision: str,
    reason: str,
    protected: dict[str, Any] | None = None,
) -> None:
    write_action_log(
        action_record(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            decision=decision,
            reason=reason,
            protected=protected,
        )
    )


def action_record(
    *,
    event: str,
    payload: dict[str, Any],
    base_path: Path | None,
    cwd: Path,
    operation: dict[str, Any],
    decision: str,
    reason: str,
    protected: dict[str, Any] | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    tool_input = operation.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    record: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "session_id": payload_string(
            payload,
            "session_id",
            "sessionId",
            "conversation_id",
            "conversationId",
            "thread_id",
            "threadId",
        ),
        "turn_id": payload_string(payload, "turn_id", "turnId"),
        "transcript_path": payload_string(payload, "transcript_path", "transcriptPath"),
        "base_path": str(base_path or ""),
        "payload_cwd": str(resolve_path(str(payload.get("cwd") or ""))) if payload.get("cwd") else "",
        "effective_cwd": str(cwd),
        "operation_workdir": operation_workdir(tool_input),
        "tool_input_keys": sorted(str(key) for key in tool_input.keys()),
        "tool_name": str(operation.get("tool_name") or ""),
        "command": str(operation.get("command") or ""),
        "decision": decision,
        "reason": reason,
    }
    if protected:
        record["protected"] = True
        record["default_protected"] = bool(protected.get("default_protected"))
        record["protected_branch"] = str(protected.get("branch") or "")
    else:
        record["protected"] = False
        record["default_protected"] = False
        record["protected_branch"] = ""
    if extra:
        record.update(extra)
    return record


def write_action_log(record: dict[str, Any]) -> None:
    write_jsonl_record(action_log_path(), record)


def write_denial_log(record: dict[str, Any]) -> None:
    write_jsonl_record(deny_log_path(), record)


def write_jsonl_record(path: Path, record: dict[str, Any]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        return


def operation_workdir(tool_input: dict[str, Any]) -> str:
    for key in ("workdir", "cwd", "working_directory", "directory"):
        value = tool_input.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def payload_string(payload: dict[str, Any], *keys: str) -> str:
    for key in keys:
        value = payload.get(key)
        if value is not None:
            return str(value)
    return ""


def read_action_records() -> list[dict[str, Any]]:
    return read_jsonl_records(action_log_path())


def read_denial_records() -> list[dict[str, Any]]:
    return read_jsonl_records(deny_log_path())


def read_jsonl_records(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    records: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for line in lines:
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def load_hook_payload(stdin: bytes) -> dict[str, Any]:
    if not stdin.strip():
        return {}
    try:
        payload = json.loads(stdin.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def load_state() -> dict[str, Any]:
    path = state_path()
    if not path.is_file():
        return {"version": 1, "repos": {}, "worktrees": {}, "grants": [], "sessions": {}}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"version": 1, "repos": {}, "worktrees": {}, "grants": [], "sessions": {}}
    if not isinstance(payload, dict):
        return {"version": 1, "repos": {}, "worktrees": {}, "grants": [], "sessions": {}}
    payload.setdefault("version", 1)
    payload.setdefault("repos", {})
    payload.setdefault("worktrees", {})
    payload.setdefault("grants", [])
    payload.setdefault("sessions", {})
    return payload


def save_state(state: dict[str, Any]) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def request_human_approval(
    *,
    repo: "Repo",
    reason: str,
    requested_scope: str,
    timeout: int,
) -> str | None:
    override = os.environ.get("WTG_APPROVAL_RESPONSE")
    if override:
        normalized = override.strip().lower()
        if normalized in {"allow", "approve", "session"}:
            return "session" if requested_scope == "session" else "once"
        if normalized in {"once", "operation"}:
            return "once"
        return None

    if sys.platform != "darwin":
        raise WorktreeGuardError(
            "No approval UI is available on this platform in WorktreeGuard-lite."
        )

    prompt = (
        "The coding agent is requesting protected base checkout access.\n\n"
        f"Repo: {repo.base_path}\n"
        f"Branch: {repo.branch}\n"
        f"Scope requested: {requested_scope}\n\n"
        f"Reason:\n{reason}"
    )
    script = [
        "display dialog "
        + apple_string(prompt)
        + ' buttons {"Deny", "Allow once", "Allow session"} '
        + 'default button "Deny" cancel button "Deny" with icon caution',
        "button returned of result",
    ]
    args = ["osascript"]
    for expression in script:
        args.extend(["-e", expression])

    try:
        result = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout if timeout > 0 else None,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None
    if result.returncode != 0:
        return None
    button = result.stdout.strip()
    if button == "Allow session":
        return "session"
    if button == "Allow once":
        return "once"
    return None


def create_grant(
    *,
    base_path: Path,
    scope: str,
    reason: str,
    ttl_seconds: int,
) -> dict[str, Any]:
    now = int(time.time())
    grant = {
        "id": f"grant-{now}-{os.getpid()}",
        "base_path": str(base_path),
        "scope": scope,
        "reason": reason,
        "created_at": now,
        "expires_at": now + max(1, ttl_seconds),
    }
    state = load_state()
    grants = state.setdefault("grants", [])
    if not isinstance(grants, list):
        grants = []
        state["grants"] = grants
    grants.append(grant)
    save_state(state)
    return grant


def has_valid_grant(base_path: Path) -> bool:
    state = load_state()
    now = int(time.time())
    changed = False
    for grant in state.get("grants", []):
        if not isinstance(grant, dict):
            continue
        if grant.get("base_path") != str(base_path):
            continue
        if int(grant.get("expires_at", 0)) <= now:
            continue
        if grant.get("revoked_at") is not None:
            continue
        scope = grant.get("scope")
        if scope == "session":
            return True
        if scope in {"once", "operation"} and grant.get("used_at") is None:
            grant["used_at"] = now
            changed = True
            save_state(state)
            return True
    if changed:
        save_state(state)
    return False


def active_grants(state: dict[str, Any]) -> list[dict[str, Any]]:
    now = int(time.time())
    result = []
    for grant in state.get("grants", []):
        if not isinstance(grant, dict):
            continue
        if int(grant.get("expires_at", 0)) <= now:
            continue
        if grant.get("revoked_at") is not None:
            continue
        if grant.get("scope") in {"once", "operation"} and grant.get("used_at") is not None:
            continue
        result.append(grant)
    return result


def apple_string(value: str) -> str:
    lines = value.splitlines() or [""]
    quoted_lines = [
        '"' + line.replace("\\", "\\\\").replace('"', '\\"') + '"'
        for line in lines
    ]
    return " & return & ".join(quoted_lines)


def state_path() -> Path:
    override = os.environ.get("WTG_STATE_FILE")
    if override:
        return resolve_path(override)
    return Path.home() / ".local" / "state" / "worktreeguard" / "lite-state.json"


def action_log_path() -> Path:
    override = os.environ.get("WTG_ACTION_LOG_FILE")
    if override:
        return resolve_path(override)
    return Path.home() / DEFAULT_ACTION_LOG_FILE


def deny_log_path() -> Path:
    override = os.environ.get("WTG_DENY_LOG_FILE")
    if override:
        return resolve_path(override)
    return Path.home() / DEFAULT_DENY_LOG_FILE


def stable_hook_shim_path(harness: str) -> Path:
    return Path.home() / ".local" / "bin" / f"wtg-hook-{harness}"


def discover_repo(path: Path) -> "Repo":
    path = resolve_path(path)
    worktree_path = resolve_path(git(path, "rev-parse", "--show-toplevel").stdout.strip())
    raw_common_git_dir = Path(git(path, "rev-parse", "--git-common-dir").stdout.strip())
    common_git_dir = raw_common_git_dir if raw_common_git_dir.is_absolute() else path / raw_common_git_dir
    branch_result = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=str(path),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    branch = branch_result.stdout.strip() or "HEAD"
    head = git(path, "rev-parse", "HEAD").stdout.strip()
    main_worktree = git_main_worktree(path) or worktree_path
    return Repo(
        base_path=main_worktree,
        worktree_path=worktree_path,
        common_git_dir=resolve_path(common_git_dir),
        branch=branch,
        head=head,
    )


def git_main_worktree(cwd: Path) -> Path | None:
    result = subprocess.run(
        ["git", "worktree", "list", "--porcelain"],
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            return resolve_path(line.removeprefix("worktree "))
    return None


def git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise WorktreeGuardError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result


def resolve_path(raw_path: str | Path) -> Path:
    return Path(raw_path).expanduser().resolve(strict=False)


def path_contains(parent: Path, child: Path) -> bool:
    try:
        child.relative_to(parent)
    except ValueError:
        return False
    return True


def command_name() -> str:
    raw = os.environ.get("WTG_COMMAND") or sys.argv[0] or "wtg"
    if raw == "wtg":
        return "wtg"
    return shlex.quote(str(resolve_path(raw)))


def emit(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


class WorktreeGuardError(RuntimeError):
    pass


class Repo:
    def __init__(
        self,
        *,
        base_path: Path,
        worktree_path: Path,
        common_git_dir: Path,
        branch: str,
        head: str,
    ) -> None:
        self.base_path = base_path
        self.worktree_path = worktree_path
        self.common_git_dir = common_git_dir
        self.branch = branch
        self.head = head

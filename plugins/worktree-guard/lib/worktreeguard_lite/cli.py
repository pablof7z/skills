"""Command-line interface for WorktreeGuard-lite."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from collections import Counter
from pathlib import Path

from .audit import read_action_records, read_denial_records
from .core import DEFAULT_GRANT_TTL_SECONDS, WorktreeGuardError, emit, path_contains, resolve_path
from .git import discover_repo, git
from .hooks import cmd_hook_harness
from .reporting import (
    color_enabled,
    filter_action_records,
    filter_denial_records,
    follow_actions,
    follow_denials,
    print_action_summary,
    print_denial_summary,
)
from .repositories import protected_repo_for_path
from .storage import (
    action_log_path,
    active_grants,
    create_grant,
    deny_log_path,
    load_state,
    request_human_approval,
    save_state,
    stable_hook_shim_path,
    state_path,
)


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

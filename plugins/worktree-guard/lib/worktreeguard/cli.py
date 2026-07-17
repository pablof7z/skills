"""Command-line interface for WorktreeGuard."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

from .core import BLOCKED_GIT_COMMANDS, DEFAULT_GRANT_TTL_SECONDS, WorktreeGuardError, emit, resolve_path
from .git import discover_repo
from .hooks import cmd_hook_harness
from .storage import (
    active_grants, create_grant, deny_log_path, read_denials, request_human_approval,
    stable_hook_shim_path, state_path,
)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except WorktreeGuardError as error:
        if getattr(args, "json", False):
            emit({"error": {"type": "worktreeguard_error", "message": str(error)}})
        else:
            print(str(error), file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wtg")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name, help_text, handler in (
        ("status", "Show whether a path is a base checkout or linked worktree", cmd_status),
        ("current", "Show current repository context as JSON", cmd_current),
    ):
        command = subparsers.add_parser(name, help=help_text)
        command.add_argument("--repo", default=".")
        command.set_defaults(func=handler)

    request = subparsers.add_parser(
        "request-base-access", help="Ask locally for a temporary blocked-command override"
    )
    request.add_argument("--repo", default=".")
    request.add_argument("--reason", required=True)
    request.add_argument("--scope", default="session", choices=["once", "operation", "session"])
    request.add_argument("--ttl-seconds", type=int, default=DEFAULT_GRANT_TTL_SECONDS)
    request.add_argument("--timeout", type=int, default=0)
    request.set_defaults(func=cmd_request_base_access)

    doctor = subparsers.add_parser("doctor", help="Check the local WorktreeGuard installation")
    doctor.set_defaults(func=cmd_doctor)

    denials = subparsers.add_parser("denials", help="Inspect blocked Git command records")
    denials.add_argument("--tail", type=int, default=20)
    denials.add_argument("--repo")
    denials.add_argument("--session")
    denials.add_argument("--json", action="store_true")
    denials.set_defaults(func=cmd_denials)

    hook = subparsers.add_parser("hook", help="Run a harness hook")
    harnesses = hook.add_subparsers(dest="harness", required=True)
    for harness_name in ("codex", "claude"):
        harness = harnesses.add_parser(harness_name)
        harness.add_argument("event", nargs="?", default="hook")
        harness.set_defaults(func=cmd_hook_harness)
    return parser


def cmd_status(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    if repo.worktree_path == repo.base_path:
        print(f"Base checkout guarded: {repo.base_path}")
        print("Blocked Git commands: " + ", ".join(sorted(BLOCKED_GIT_COMMANDS)))
    else:
        print(f"Linked worktree unrestricted: {repo.worktree_path}")
        print(f"Base checkout: {repo.base_path}")
    return 0


def cmd_current(args: argparse.Namespace) -> int:
    path = resolve_path(args.repo)
    repo = discover_repo(path)
    emit({
        "cwd": str(path),
        "base_checkout": str(repo.base_path),
        "worktree": str(repo.worktree_path),
        "is_base_checkout": repo.worktree_path == repo.base_path,
        "blocked_git_commands": sorted(BLOCKED_GIT_COMMANDS),
    })
    return 0


def cmd_request_base_access(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    if repo.worktree_path != repo.base_path:
        raise WorktreeGuardError("This is already a linked worktree; no override is needed.")
    decision = request_human_approval(
        repo=repo, reason=args.reason, requested_scope=args.scope, timeout=args.timeout
    )
    if decision is None:
        print("Denied. Run the Git command from a linked worktree instead.", file=sys.stderr)
        return 1
    grant = create_grant(
        base_path=repo.base_path, scope=decision, reason=args.reason,
        ttl_seconds=args.ttl_seconds, session_id=os.environ.get("WTG_SESSION_ID", ""),
    )
    expires = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(grant["expires_at"]))
    print(f"Approved {decision} override until {expires}. Retry the command.")
    return 0


def cmd_doctor(_args: argparse.Namespace) -> int:
    git_path = shutil.which("git")
    print(f"git: {git_path or 'missing'}")
    print(f"state: {state_path()}")
    print(f"deny log: {deny_log_path()}")
    for harness in ("codex", "claude"):
        shim = stable_hook_shim_path(harness)
        status = "executable" if os.access(shim, os.X_OK) else "missing"
        print(f"hook shim ({harness}): {shim} ({status})")
    print("blocked Git commands: " + ", ".join(sorted(BLOCKED_GIT_COMMANDS)))
    print(f"active overrides: {len(active_grants())}")
    return 0 if git_path else 1


def cmd_denials(args: argparse.Namespace) -> int:
    records = read_denials()
    if args.repo:
        repo = str(resolve_path(args.repo))
        records = [record for record in records if record.get("base_path") == repo]
    if args.session:
        records = [record for record in records if record.get("session_id") == args.session]
    tail = records[-max(0, args.tail) :] if args.tail else []
    if args.json:
        emit({"log": str(deny_log_path()), "total": len(records), "tail": tail})
    else:
        print(f"Denied commands: {len(records)} ({deny_log_path()})")
        for record in tail:
            print(
                f"{record.get('timestamp', '')} git {record.get('subcommand', '')} "
                f"in {record.get('base_path', '')}"
            )
    return 0

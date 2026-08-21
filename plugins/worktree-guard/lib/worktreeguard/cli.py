"""Command-line interface for WorktreeGuard."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

from .audit import request_record
from .core import BLOCKED_GIT_COMMANDS, DEFAULT_GRANT_TTL_SECONDS, WorktreeGuardError, emit, resolve_path
from .git import discover_repo
from .hooks import cmd_hook_harness
from .notifications import notify_auto_grant
from .install import install_hooks
from .storage import (
    VALID_REPO_MODES, active_grants, all_repo_modes, auto_grant_base_edits_enabled, create_grant,
    deny_log_path, read_denials, read_requests, repo_mode, request_human_approval, request_log_path,
    set_auto_grant_base_edits, set_repo_mode, stable_hook_shim_path, state_path, write_request,
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
    request.add_argument("--ttl-seconds", type=int, default=DEFAULT_GRANT_TTL_SECONDS)
    request.add_argument("--timeout", type=int, default=0)
    request.set_defaults(func=cmd_request_base_access)

    config = subparsers.add_parser("config", help="Inspect or change WorktreeGuard preferences")
    config_settings = config.add_subparsers(dest="setting", required=True)
    auto_grant = config_settings.add_parser(
        "auto-grant-edits", help="Show or change native base-edit auto grants"
    )
    auto_grant.add_argument("value", nargs="?", choices=["on", "off"])
    auto_grant.set_defaults(func=cmd_config_auto_grant_edits)

    repo_config = config_settings.add_parser(
        "repo", help="Show or change the per-repo guard mode"
    )
    repo_config.add_argument("path", nargs="?")
    repo_config.add_argument("value", nargs="?", choices=sorted(VALID_REPO_MODES))
    repo_config.add_argument(
        "--list", action="store_true", help="List all configured per-repo modes"
    )
    repo_config.set_defaults(func=cmd_config_repo)

    doctor = subparsers.add_parser("doctor", help="Check the local WorktreeGuard installation")
    doctor.set_defaults(func=cmd_doctor)

    install = subparsers.add_parser(
        "install-hooks",
        help="Install stable hook shims and register the Grok global hook",
    )
    install.add_argument(
        "--no-grok",
        action="store_true",
        help="Skip writing ~/.grok/hooks/worktree-guard.json",
    )
    install.set_defaults(func=cmd_install_hooks)

    denials = subparsers.add_parser("denials", help="Inspect blocked Git command records")
    denials.add_argument("--tail", type=int, default=20)
    denials.add_argument("--repo")
    denials.add_argument("--session")
    denials.add_argument("--json", action="store_true")
    denials.set_defaults(func=cmd_denials)

    requests = subparsers.add_parser(
        "requests", help="Inspect past request-base-access reasons"
    )
    requests.add_argument("--tail", type=int, default=20)
    requests.add_argument("--repo")
    requests.add_argument("--session")
    requests.add_argument("--json", action="store_true")
    requests.set_defaults(func=cmd_requests)

    hook = subparsers.add_parser("hook", help="Run a harness hook")
    harnesses = hook.add_subparsers(dest="harness", required=True)
    for harness_name in ("codex", "claude", "grok"):
        harness = harnesses.add_parser(harness_name)
        harness.add_argument("event", nargs="?", default="hook")
        harness.set_defaults(func=cmd_hook_harness)
    return parser


def cmd_status(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    if repo.worktree_path == repo.base_path:
        print(f"Base checkout guarded: {repo.base_path}")
        print("Blocked Git commands: " + ", ".join(sorted(BLOCKED_GIT_COMMANDS)))
        print(f"Auto-grant base access requests: {on_off(auto_grant_base_edits_enabled())}")
        print(f"Guard mode: {repo_mode(repo.base_path)}")
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
        "auto_grant_base_edits": auto_grant_base_edits_enabled(),
        "guard_mode": repo_mode(repo.base_path),
    })
    return 0


def cmd_request_base_access(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    if repo.worktree_path != repo.base_path:
        raise WorktreeGuardError("This is already a linked worktree; no override is needed.")
    session_id = current_session_id()
    if not session_id:
        raise WorktreeGuardError(
            "Cannot determine the current Codex, Claude Code, or Grok session; "
            "no access was granted."
        )
    if auto_grant_base_edits_enabled():
        approved = True
        method = "auto_grant"
        notify_auto_grant(repo.base_path, reason=args.reason, session_id=session_id)
    else:
        approved = request_human_approval(repo=repo, reason=args.reason, timeout=args.timeout)
        method = "human_approval"
    write_request(request_record(
        base_path=repo.base_path, reason=args.reason, session_id=session_id,
        approved=approved, method=method,
    ))
    if not approved:
        print("Denied. Run the Git command from a linked worktree instead.", file=sys.stderr)
        return 1
    grant = create_grant(
        base_path=repo.base_path, reason=args.reason,
        ttl_seconds=args.ttl_seconds, session_id=session_id,
    )
    expires = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(grant["expires_at"]))
    print(f"Approved session override until {expires}. Retry the command.")
    return 0


def current_session_id() -> str:
    for name in (
        "WTG_SESSION_ID",
        "GROK_SESSION_ID",
        "CLAUDE_CODE_SESSION_ID",
        "CODEX_THREAD_ID",
    ):
        session_id = os.environ.get(name, "").strip()
        if session_id:
            return session_id
    return ""


def cmd_config_auto_grant_edits(args: argparse.Namespace) -> int:
    if args.value is not None:
        set_auto_grant_base_edits(args.value == "on")
    print(f"auto-grant-edits: {on_off(auto_grant_base_edits_enabled())}")
    return 0


def cmd_config_repo(args: argparse.Namespace) -> int:
    if args.list:
        modes = all_repo_modes()
        if not modes:
            print("No per-repo modes configured (all repos use full).")
            return 0
        for path in sorted(modes):
            print(f"{path}: {modes[path]}")
        return 0
    if not args.path:
        raise WorktreeGuardError("A repository path is required (or pass --list).")
    repo = discover_repo(Path(args.path))
    if args.value is not None:
        set_repo_mode(repo.base_path, args.value)
    print(f"repo {repo.base_path}: {repo_mode(repo.base_path)}")
    return 0


def cmd_doctor(_args: argparse.Namespace) -> int:
    git_path = shutil.which("git")
    print(f"git: {git_path or 'missing'}")
    print(f"state: {state_path()}")
    print(f"deny log: {deny_log_path()}")
    print(f"request log: {request_log_path()}")
    for harness in ("codex", "claude", "grok", "dispatch"):
        shim = stable_hook_shim_path(harness)
        status = "executable" if os.access(shim, os.X_OK) else "missing"
        print(f"hook shim ({harness}): {shim} ({status})")
    grok_hook = Path.home() / ".grok" / "hooks" / "worktree-guard.json"
    print(
        f"grok global hook: {grok_hook} "
        f"({'present' if grok_hook.is_file() else 'missing'})"
    )
    print("blocked Git commands: " + ", ".join(sorted(BLOCKED_GIT_COMMANDS)))
    print(f"auto-grant base access requests: {on_off(auto_grant_base_edits_enabled())}")
    print(f"active overrides: {len(active_grants())}")
    print(f"per-repo modes configured: {len(all_repo_modes())}")
    return 0 if git_path else 1


def cmd_install_hooks(args: argparse.Namespace) -> int:
    for message in install_hooks(grok=not args.no_grok):
        print(message)
    return 0


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
            action = (
                f"git {record.get('subcommand')}"
                if record.get("subcommand") else str(record.get("tool_name") or "mutation")
            )
            print(
                f"{record.get('timestamp', '')} {action} in {record.get('base_path', '')}"
            )
    return 0


def cmd_requests(args: argparse.Namespace) -> int:
    records = read_requests()
    if args.repo:
        repo = str(resolve_path(args.repo))
        records = [record for record in records if record.get("base_path") == repo]
    if args.session:
        records = [record for record in records if record.get("session_id") == args.session]
    tail = records[-max(0, args.tail) :] if args.tail else []
    if args.json:
        emit({"log": str(request_log_path()), "total": len(records), "tail": tail})
    else:
        print(f"Base access requests: {len(records)} ({request_log_path()})")
        for record in tail:
            outcome = "approved" if record.get("approved") else "denied"
            print(
                f"{record.get('timestamp', '')} {outcome} in {record.get('base_path', '')}: "
                f"{record.get('reason', '')}"
            )
    return 0


def on_off(value: bool) -> str:
    return "on" if value else "off"

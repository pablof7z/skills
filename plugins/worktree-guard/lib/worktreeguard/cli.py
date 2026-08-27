"""Command-line interface for WorktreeGuard."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

from .audit import SCOPE_LABELS, request_record
from .core import (
    ACCESS_SCOPES, BLOCKED_GIT_COMMANDS, DEFAULT_REQUEST_TIMEOUT_SECONDS, GUARD_GROUPS,
    WorktreeGuardError, emit, group_for_access_scope, resolve_path,
)
from .git import discover_repo
from .hooks import cmd_hook_harness
from .notifications import notify_auto_grant
from .install import install_hooks, toast_binary_path
from .storage import (
    ApprovalOutcome, active_grants, config_path, create_grant, default_config, deny_log_path,
    global_config_path, read_config, read_denials, read_requests, repo_config,
    request_human_approval, request_log_path, revoke_grants, set_config_value,
    stable_hook_shim_path, state_path, write_config, write_request,
)
from .tui import is_interactive


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


def positive_seconds(value: str) -> int:
    try:
        seconds = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive number of seconds") from error
    if seconds <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return seconds


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
        "request-base-access", help="Ask locally for session access to a blocked operation"
    )
    request.add_argument("--repo", default=".")
    request.add_argument("--reason", required=True)
    request.add_argument(
        "--timeout", type=positive_seconds, default=DEFAULT_REQUEST_TIMEOUT_SECONDS,
        help="Seconds to wait for a manual decision (default: 300)",
    )
    request.add_argument(
        "--scope", required=True, choices=ACCESS_SCOPES,
        help="The access scope to request",
    )
    request.set_defaults(func=cmd_request_base_access)

    revoke = subparsers.add_parser(
        "revoke", help="Revoke a live session access grant"
    )
    revoke.add_argument("--repo", default=".")
    revoke.add_argument(
        "--session",
        help="Only revoke this session's grant (default: every session's grant for the repo)",
    )
    revoke.add_argument(
        "--grant-id",
        help="Only revoke this exact grant (what the notification toast's revoke control uses)",
    )
    revoke.set_defaults(func=cmd_revoke)

    config = subparsers.add_parser("config", help="Inspect or set the local .wtg.json guard config")
    config.add_argument("--repo", default=".")
    config.add_argument("--json", action="store_true", help="Print effective config as JSON (skip the interactive UI)")
    config.set_defaults(func=cmd_config)
    config_set = config.add_subparsers(dest="setting", required=False)
    setter = config_set.add_parser("set", help="Set a key in .wtg.json")
    setter.add_argument(
        "key",
        help="'enabled', or '<policy>.disposition'/'<policy>.bypass'/'<policy>.message' "
        f"(policy one of: {', '.join(GUARD_GROUPS)})",
    )
    setter.add_argument("value")
    setter.set_defaults(func=cmd_config_set)
    init = config_set.add_parser("init", help="Write a default .wtg.json")
    init.set_defaults(func=cmd_config_init)

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
    config = repo_config(repo.base_path)
    if repo.worktree_path == repo.base_path:
        print(f"Base checkout guarded: {repo.base_path}")
        print("Blocked Git commands: " + ", ".join(sorted(BLOCKED_GIT_COMMANDS)))
        print(f"Config: {config_path(repo.base_path)}")
        print(f"enabled={config.enabled}")
        for group in GUARD_GROUPS:
            policy = config.policy(group)
            message = " custom-message" if policy.message is not None else ""
            print(f"  {group}: disposition={policy.disposition} bypass={policy.bypass}{message}")
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
        "config": read_config(repo.base_path),
        "config_path": str(config_path(repo.base_path)),
    })
    return 0


def cmd_request_base_access(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    if repo.worktree_path != repo.base_path:
        raise WorktreeGuardError("This is already a linked worktree; no override is needed.")
    config = repo_config(repo.base_path)
    if not config.enabled:
        print("WorktreeGuard is disabled for this repo (enabled=false); no override is needed.")
        return 0
    session_id = current_session_id()
    if not session_id:
        raise WorktreeGuardError(
            "Cannot determine the current Codex, Claude Code, or Grok session; "
            "no access was granted."
        )
    scope = args.scope
    group = group_for_access_scope(scope)
    policy = config.policy(group)
    label = SCOPE_LABELS.get(scope, scope)

    if policy.bypass == "none":
        write_request(request_record(
            base_path=repo.base_path, reason=args.reason, session_id=session_id,
            outcome="denied_by_policy", scope=scope,
        ))
        print(
            f"Denied. {label.capitalize()} are automatically denied for this repo "
            "(bypass=none). Use a linked worktree instead.", file=sys.stderr,
        )
        return 1

    if policy.bypass == "manual":
        outcome = request_human_approval(
            repo=repo, reason=args.reason, scope=scope, timeout=args.timeout,
        )
    else:
        outcome = ApprovalOutcome.APPROVED

    write_request(request_record(
        base_path=repo.base_path, reason=args.reason, session_id=session_id,
        outcome=outcome.value, scope=scope,
    ))
    if outcome is ApprovalOutcome.TIMED_OUT:
        print(
            f"No answer from the user within {args.timeout} seconds; access was not granted. "
            "Use a linked worktree or request access again.", file=sys.stderr,
        )
        return 1
    if outcome is ApprovalOutcome.REJECTED:
        print("Denied by the user. Run the command from a linked worktree instead.", file=sys.stderr)
        return 1
    grant = create_grant(
        base_path=repo.base_path, reason=args.reason, session_id=session_id, scope=scope,
        iterm_session_id=os.environ.get("ITERM_SESSION_ID", ""),
    )
    if policy.bypass == "auto":
        # Fired after the grant exists so its revoke control has a real id to
        # target — revoking must never touch a sibling grant for another scope.
        notify_auto_grant(
            repo.base_path, reason=args.reason, session_id=session_id,
            scope=scope, grant_id=grant["id"],
        )
    print(f"Approved session access for {scope}. Retry the command.")
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


def cmd_revoke(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    removed = revoke_grants(repo.base_path, session_id=args.session, grant_id=args.grant_id)
    if removed:
        print(f"Revoked {removed} grant(s) for {repo.base_path}.")
    else:
        print(f"No live grants to revoke for {repo.base_path}.")
    return 0


def cmd_config(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    if not getattr(args, "json", False) and is_interactive():
        from .tui import run_interactive_config
        return run_interactive_config(repo.base_path)
    emit(read_config(repo.base_path))
    return 0


def cmd_config_set(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    config = set_config_value(repo.base_path, args.key, args.value)
    emit(config)
    return 0


def cmd_config_init(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    path = config_path(repo.base_path)
    if path.exists():
        raise WorktreeGuardError(f"already exists: {path}")
    write_config(repo.base_path, default_config())
    print(f"wrote {path}")
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
    global_cfg = global_config_path()
    print(
        f"global config: {global_cfg} "
        f"({'present' if global_cfg.is_file() else 'not set — repos use hard-coded defaults as fallback'})"
    )
    toast = toast_binary_path()
    print(
        f"notification toast: {toast} "
        f"({'present' if toast.is_file() else 'missing — falls back to a plain approval dialog'})"
    )
    print("blocked Git commands: " + ", ".join(sorted(BLOCKED_GIT_COMMANDS)))
    print(f"active overrides: {len(active_grants())}")
    print(
        "repo config: .wtg.json per base checkout (enabled, plus "
        f"{{disposition, bypass, optional message}} per policy: {', '.join(GUARD_GROUPS)})"
    )
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
            scope = f" [{record['scope']}]" if record.get("scope") else ""
            print(
                f"{record.get('timestamp', '')} {action}{scope} in {record.get('base_path', '')}"
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
            outcome = str(record.get("outcome") or "unknown")
            scope = f" [{record['scope']}]" if record.get("scope") else ""
            print(
                f"{record.get('timestamp', '')} {outcome}{scope} in {record.get('base_path', '')}: "
                f"{record.get('reason', '')}"
            )
    return 0

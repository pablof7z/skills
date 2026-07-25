"""Command-line interface for ChiefOfStaffGuard."""

from __future__ import annotations

import argparse
import os
import sys

from .core import ChiefOfStaffGuardError, emit
from .homes import agent_home, tracking_repo_home
from .hooks import cmd_hook_harness
from .identity import CLAUDE_CODE_AGENT_ENV, MOSAICO_AGENT_ENV, is_chief_of_staff_session
from .storage import deny_log_path, read_denials, stable_hook_shim_path


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ChiefOfStaffGuardError as error:
        if getattr(args, "json", False):
            emit({"error": {"type": "chief_of_staff_guard_error", "message": str(error)}})
        else:
            print(str(error), file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cosg")
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("status", help="Show whether the current session is guarded")
    status.set_defaults(func=cmd_status)

    doctor = subparsers.add_parser("doctor", help="Check the local ChiefOfStaffGuard installation")
    doctor.set_defaults(func=cmd_doctor)

    denials = subparsers.add_parser("denials", help="Inspect blocked action records")
    denials.add_argument("--tail", type=int, default=20)
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


def cmd_status(_args: argparse.Namespace) -> int:
    guarded = is_chief_of_staff_session(os.environ)
    print(f"chief-of-staff session: {'yes' if guarded else 'no'}")
    print(f"{MOSAICO_AGENT_ENV}={os.environ.get(MOSAICO_AGENT_ENV, '')!r}")
    print(f"{CLAUDE_CODE_AGENT_ENV}={os.environ.get(CLAUDE_CODE_AGENT_ENV, '')!r}")
    print(f"tracking repo home: {tracking_repo_home()}")
    print(f"agent home: {agent_home()}")
    return 0


def cmd_doctor(_args: argparse.Namespace) -> int:
    print(f"deny log: {deny_log_path()}")
    for harness in ("codex", "claude"):
        shim = stable_hook_shim_path(harness)
        status = "executable" if os.access(shim, os.X_OK) else "missing"
        print(f"hook shim ({harness}): {shim} ({status})")
    print(f"tracking repo home: {tracking_repo_home()}")
    print(f"agent home: {agent_home()}")
    print("self-serve override: none by design -- see README")
    return 0


def cmd_denials(args: argparse.Namespace) -> int:
    records = read_denials()
    if args.session:
        records = [record for record in records if record.get("session_id") == args.session]
    tail = records[-max(0, args.tail) :] if args.tail else []
    if args.json:
        emit({"log": str(deny_log_path()), "total": len(records), "tail": tail})
    else:
        print(f"Denied actions: {len(records)} ({deny_log_path()})")
        for record in tail:
            action = record.get("program") or record.get("tool_name") or "action"
            print(f"{record.get('timestamp', '')} {action}: {record.get('reason', '')}")
    return 0

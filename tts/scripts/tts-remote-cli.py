#!/usr/bin/env python3
"""Top-level remote TTS command router."""

from __future__ import annotations

import argparse
import json
import sys

from tts_remote_state import error
from tts_remote_commands import (
    daemon_run,
    daemon_start,
    daemon_status,
    daemon_stop,
    pair_connect,
    pair_list,
    pair_offer,
    pair_revoke,
    pair_status,
    remote_speak,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tts")
    commands = parser.add_subparsers(dest="command", required=True)

    pair = commands.add_parser("pair")
    pair_commands = pair.add_subparsers(dest="pair_command", required=True)
    offer = pair_commands.add_parser("offer")
    offer.add_argument("--relay")
    offer.add_argument("--channel")
    offer.set_defaults(func=pair_offer)
    connect = pair_commands.add_parser("connect")
    connect.add_argument("--code", required=True)
    connect.set_defaults(func=pair_connect)
    pair_commands.add_parser("list").set_defaults(func=pair_list)
    pair_commands.add_parser("status").set_defaults(func=pair_status)
    revoke = pair_commands.add_parser("revoke")
    revoke.add_argument("peer")
    revoke.set_defaults(func=pair_revoke)

    remote = commands.add_parser("remote")
    remote_commands = remote.add_subparsers(dest="remote_command", required=True)
    speak = remote_commands.add_parser("speak")
    speak.add_argument("--peer")
    speak.add_argument("--agent-name", required=True)
    speak.add_argument("--subject", required=True)
    speak.add_argument("--message", required=True)
    speak.add_argument("--attach", nargs=2, action="append", default=[])
    speak.set_defaults(func=remote_speak, attach_flat=True)

    daemon = commands.add_parser("daemon")
    daemon_commands = daemon.add_subparsers(dest="daemon_command", required=True)
    daemon_commands.add_parser("status").set_defaults(func=daemon_status)
    start = daemon_commands.add_parser("start")
    start.add_argument("--dry-run", action="store_true")
    start.set_defaults(func=daemon_start)
    daemon_commands.add_parser("stop").set_defaults(func=daemon_stop)
    run = daemon_commands.add_parser("run")
    run.add_argument("--once", action="store_true")
    run.add_argument("--max-events", type=int, default=100)
    run.add_argument("--wait-seconds", type=float)
    run.set_defaults(func=daemon_run)
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "attach_flat", False):
        args.attach = [part for pair in args.attach for part in pair]
    try:
        return args.func(args)
    except RuntimeError as exc:
        print(json.dumps(error("remote_transport_error", str(exc)), sort_keys=True), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

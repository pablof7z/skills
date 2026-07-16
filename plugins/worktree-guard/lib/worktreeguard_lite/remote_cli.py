"""CLI handlers for WorktreeGuard remote approval."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

from .core import emit
from .remote_approval import consume_decision, laptop_requests, publish_decision
from .remote_daemon import daemon_pid_path, daemon_status, start_daemon, stop_daemon
from .remote_pairing import connect_pair_code, create_pair_offer, pair_status, revoke_peer
from .storage import apple_string, load_state


def add_remote_parsers(subparsers: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    pair = subparsers.add_parser("pair", help="Pair with an attended approval laptop")
    pair_sub = pair.add_subparsers(dest="pair_command", required=True)

    offer = pair_sub.add_parser("offer", help="Create a laptop pairing offer")
    offer.add_argument("--relay", required=True)
    offer.add_argument("--ttl-seconds", type=int, default=600)
    offer.add_argument("--json", action="store_true")
    offer.set_defaults(func=cmd_pair_offer)

    connect = pair_sub.add_parser("connect", help="Connect this server to a laptop pair code")
    connect.add_argument("pair_code")
    connect.add_argument("--json", action="store_true")
    connect.set_defaults(func=cmd_pair_connect)

    status = pair_sub.add_parser("status", help="Show pairing status")
    status.add_argument("--json", action="store_true")
    status.set_defaults(func=cmd_pair_status)

    pair_sub.add_parser("list", help="List paired approval laptops").set_defaults(func=cmd_pair_list)
    revoke = pair_sub.add_parser("revoke", help="Revoke a paired approval laptop")
    revoke.add_argument("pubkey")
    revoke.add_argument("--json", action="store_true")
    revoke.set_defaults(func=cmd_pair_revoke)

    daemon = subparsers.add_parser("daemon", help="Run or inspect remote approval daemons")
    daemon_sub = daemon.add_subparsers(dest="daemon_command", required=True)
    daemon_sub.add_parser("status", help="Show daemon pairing readiness").set_defaults(func=cmd_daemon_status)
    server = daemon_sub.add_parser("server", help="Process remote approval decisions")
    server.add_argument("action", nargs="?", default="foreground", choices=["foreground", "start", "status", "stop"])
    server.add_argument("--once", action="store_true")
    server.add_argument("--timeout", type=int, default=0)
    server.set_defaults(func=cmd_daemon_server)
    laptop = daemon_sub.add_parser("laptop", help="Listen for approval requests on this laptop")
    laptop.add_argument("action", nargs="?", default="foreground", choices=["foreground", "start", "status", "stop"])
    laptop.add_argument("--once", action="store_true")
    laptop.add_argument("--timeout", type=int, default=0)
    laptop.set_defaults(func=cmd_daemon_laptop)


def cmd_pair_offer(args: argparse.Namespace) -> int:
    offer = create_pair_offer(relay=args.relay, ttl_seconds=args.ttl_seconds)
    payload = {
        "pair_code": offer.pair_code,
        "relay": offer.relay,
        "laptop_pubkey": offer.laptop_pubkey,
        "pairing_id": offer.pairing_id,
        "secret": offer.secret,
        "expires_at": offer.expires_at,
    }
    if args.json:
        emit(payload)
    else:
        print("Run this on the server that needs approval:")
        print(f"  wtg pair connect '{offer.pair_code}'")
    return 0


def cmd_pair_connect(args: argparse.Namespace) -> int:
    payload = connect_pair_code(args.pair_code)
    if args.json:
        emit(payload)
    else:
        print(f"Paired approval laptop: {payload['laptop_pubkey']}")
    return 0


def cmd_pair_status(args: argparse.Namespace) -> int:
    payload = pair_status()
    if args.json:
        emit(payload)
    else:
        print(f"backend: {payload.get('backend') or 'not configured'}")
        print(f"approved peers: {len(payload.get('approved_peers', {}))}")
    return 0


def cmd_pair_list(args: argparse.Namespace) -> int:
    peers = pair_status().get("approved_peers", {})
    for pubkey, peer in peers.items():
        print(f"{pubkey} {peer.get('relay', '')}")
    return 0


def cmd_pair_revoke(args: argparse.Namespace) -> int:
    revoked = revoke_peer(args.pubkey)
    payload = {"pubkey": args.pubkey, "revoked": revoked}
    if args.json:
        emit(payload)
    else:
        print("revoked" if revoked else "not paired")
    return 0 if revoked else 1


def cmd_daemon_status(args: argparse.Namespace) -> int:
    remote = load_state().get("remote", {})
    emit(
        {
            "backend_ready": bool(remote.get("backend")),
            "approved_peer_count": len(remote.get("approved_peers", {})),
            "pending_request_count": len(remote.get("pending_requests", {})),
        }
    )
    return 0


def cmd_daemon_server(args: argparse.Namespace) -> int:
    lifecycle = handle_daemon_lifecycle("server", args)
    if lifecycle is not None:
        emit(lifecycle)
        return 0 if not lifecycle.get("running") or args.action != "stop" else 1
    deadline = daemon_deadline(args)
    processed = 0
    try:
        while True:
            pending = load_state().get("remote", {}).get("pending_requests", {})
            for request_id, record in list(pending.items()):
                if isinstance(record, dict) and record.get("used_at") is None:
                    if consume_decision(request_id, deadline) is not None:
                        processed += 1
            if args.once or time.monotonic() >= deadline:
                emit({"status": "stopped", "processed": processed})
                return 0
            time.sleep(0.25)
    finally:
        cleanup_foreground_pid("server")


def cmd_daemon_laptop(args: argparse.Namespace) -> int:
    lifecycle = handle_daemon_lifecycle("laptop", args)
    if lifecycle is not None:
        emit(lifecycle)
        return 0 if not lifecycle.get("running") or args.action != "stop" else 1
    deadline = daemon_deadline(args)
    processed = 0
    seen: set[str] = set()
    try:
        while True:
            for request in laptop_requests(deadline):
                request_id = str(request["id"])
                if request_id in seen:
                    continue
                seen.add(request_id)
                decision = choose_laptop_decision(request)
                if decision:
                    publish_decision(request_id, decision)
                    processed += 1
            if args.once or time.monotonic() >= deadline:
                emit({"status": "stopped", "processed": processed})
                return 0
            time.sleep(0.25)
    finally:
        cleanup_foreground_pid("laptop")


def handle_daemon_lifecycle(role: str, args: argparse.Namespace) -> dict[str, object] | None:
    if args.action == "start":
        return start_daemon(role, timeout=args.timeout)
    if args.action == "status":
        return daemon_status(role)
    if args.action == "stop":
        return stop_daemon(role)
    return None


def cleanup_foreground_pid(role: str) -> None:
    path = daemon_pid_path(role)
    try:
        current = int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return
    if current == os.getpid():
        try:
            path.unlink()
        except OSError:
            pass


def daemon_deadline(args: argparse.Namespace) -> float:
    if args.once or args.timeout > 0:
        return time.monotonic() + max(0, args.timeout)
    return float("inf")


def choose_laptop_decision(request: dict[str, object]) -> str | None:
    override = os.environ.get("WTG_APPROVAL_RESPONSE")
    if override:
        normalized = override.strip().lower()
        if normalized in {"allow", "approve", "session", "allow-session"}:
            return "allow-session"
        if normalized in {"once", "operation", "allow-once"}:
            return "allow-once"
        return "deny"
    prompt = (
        "WorktreeGuard approval request.\n\n"
        f"Repository: {request.get('repository')}\n"
        f"Worktree: {request.get('worktree')}\n"
        f"Operation: {request.get('operation')}\n"
        f"Scope requested: {request.get('requested_scope')}\n"
        f"Session: {request.get('session')}\n\n"
        f"Reason:\n{request.get('reason')}"
    )
    if sys.platform != "darwin":
        print(prompt, file=sys.stderr)
        return None
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
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        return "deny"
    button = result.stdout.strip()
    if button == "Allow session":
        return "allow-session"
    if button == "Allow once":
        return "allow-once"
    return "deny"
    return 0

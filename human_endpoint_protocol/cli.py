"""Executable contract checks for remote human endpoint integrations."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

from .errors import RemoteHumanError
from .models import PairingCode
from .transport import NakTransport


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except RemoteHumanError as error:
        print(error.to_json(), file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="human-endpoint")
    subparsers = parser.add_subparsers(dest="command", required=True)

    vectors = subparsers.add_parser("vectors", help="Print executable protocol test vectors")
    vectors.set_defaults(func=cmd_vectors)

    validate = subparsers.add_parser("validate-pairing-code", help="Validate a pairing-code JSON blob")
    validate.add_argument("json")
    validate.add_argument("--product", required=True)
    validate.set_defaults(func=cmd_validate_pairing_code)

    doctor = subparsers.add_parser("doctor", help="Check local transport dependencies")
    doctor.add_argument("--nak-path", default="nak")
    doctor.set_defaults(func=cmd_doctor)

    publish = subparsers.add_parser("publish-nak", help="Publish a raw event through nak")
    publish.add_argument("--relay-url", required=True)
    publish.add_argument("--nsec", required=True)
    publish.add_argument("--nak-path", default="nak")
    publish.add_argument("event_json")
    publish.set_defaults(func=cmd_publish_nak)

    return parser


def cmd_vectors(args: argparse.Namespace) -> int:
    path = Path(__file__).with_name("test_vectors.json")
    print(path.read_text(encoding="utf-8").rstrip())
    return 0


def cmd_validate_pairing_code(args: argparse.Namespace) -> int:
    code = PairingCode.from_json(args.json)
    if code.product != args.product:
        raise RemoteHumanError("product_mismatch", "Pairing code is for a different product.")
    print(json.dumps({"ok": True, "pairing_id": code.pairing_id}, sort_keys=True))
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    nak = shutil.which(args.nak_path)
    payload = {
        "ok": nak is not None,
        "transport": "nak",
        "nak_path": args.nak_path,
        "resolved_path": nak,
    }
    print(json.dumps(payload, sort_keys=True))
    return 0 if nak else 1


def cmd_publish_nak(args: argparse.Namespace) -> int:
    try:
        event = json.loads(args.event_json)
    except json.JSONDecodeError as error:
        raise RemoteHumanError("invalid_event", "event_json must be valid JSON.") from error
    transport = NakTransport(relay_url=args.relay_url, nsec=args.nsec, nak_path=args.nak_path)
    print(json.dumps(transport.publish(event), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

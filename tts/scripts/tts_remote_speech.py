#!/usr/bin/env python3
"""Send speech and blocking asks through a paired TTS endpoint."""

from __future__ import annotations

import json
import os
import sys
import uuid

from tts_remote_ask import prepare_ask, wait_for_answer
from tts_remote_channel import channel_parts
from tts_remote_groups import ensure_group_member
from tts_remote_protocol import request_tags
from tts_remote_signing import public_key, signed_event
from tts_remote_state import active_peer, ensure_backend, error
from tts_remote_transport import transport


def remote_speak(args) -> int:
    ask = prepare_ask(args.ask, args.wait)
    backend = ensure_backend()
    peer = active_peer(args.peer)
    if not peer:
        return fail(
            "not_paired",
            "no approved TTS laptop pairing found",
            "Run tts pair offer on the laptop, then tts pair connect on this host.",
        )
    signer_nsec = os.environ.get("AGENT_NSEC") or str(backend["nsec"])
    signer_pubkey = public_key(signer_nsec)
    pairing_relay = str(peer.get("relay") or "")
    channel = str(peer.get("channel") or peer.get("group_id") or "")
    relay, group_id = channel_parts(channel, pairing_relay)
    if os.environ.get("AGENT_NSEC"):
        ensure_group_member(relay, group_id, str(backend["nsec"]), signer_pubkey)
    attachments = [
        {"label": label, "path": path}
        for label, path in zip(args.attach[0::2], args.attach[1::2])
    ]
    request_id = str(uuid.uuid4())
    event = signed_event(
        kind=9,
        content=args.message,
        tags=request_tags(
            peer_pubkey=str(peer["pubkey"]),
            group_id=group_id,
            backend_pubkey=str(backend["pubkey"]),
            request_id=request_id,
            subject=args.subject,
            agent_name=args.agent_name,
            attachments=attachments,
            ask=ask,
            wait=args.wait,
        ),
        nsec=signer_nsec,
        relay=relay,
    )
    transport(relay).publish(event)
    sent = {
        "status": "sent",
        "request_id": request_id,
        "event_id": event["id"],
        "author_pubkey": signer_pubkey,
        "peer": peer["pubkey"],
    }
    if not ask:
        return emit(sent)
    answer = wait_for_answer(
        request_event=event,
        backend_pubkey=str(backend["pubkey"]),
        laptop_pubkey=str(peer["pubkey"]),
        relay=relay,
        group_id=group_id,
        wait=str(args.wait),
    )
    return emit({**sent, **answer})


def emit(value: object) -> int:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def fail(code: str, message: str, guidance: str) -> int:
    print(json.dumps(error(code, message, guidance), sort_keys=True), file=sys.stderr)
    return 1

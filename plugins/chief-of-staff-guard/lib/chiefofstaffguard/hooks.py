"""Codex and Claude hook handling for ChiefOfStaffGuard."""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any

from .audit import denial_message, denial_record
from .core import emit, resolve_path
from .identity import is_chief_of_staff_session
from .notifications import notify_denial
from .operations import extract_operation, operation_cwd, payload_string, recover_codex_exec_workdir
from .policy import blocked_operation
from .storage import load_hook_payload, write_denial


def cmd_hook_harness(args: argparse.Namespace) -> int:
    payload = load_hook_payload(sys.stdin.buffer.read())
    if args.harness == "codex":
        payload = recover_codex_exec_workdir(payload)
    return run_harness_hook(args.event, payload)


def run_harness_hook(event: str, payload: dict[str, Any]) -> int:
    if event != "pre-tool-use":
        return 0
    if not is_chief_of_staff_session(os.environ):
        return 0

    operation = extract_operation(payload)
    payload_cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    cwd = operation_cwd(operation, payload_cwd)
    blocked = blocked_operation(operation, cwd)
    if blocked is None:
        return 0

    session_id = payload_string(
        payload, "session_id", "sessionId", "conversation_id", "conversationId",
        "thread_id", "threadId",
    )
    message = denial_message(blocked)
    write_denial(denial_record(event=event, payload=payload, operation=blocked))
    notify_denial(reason=blocked.reason, session_id=session_id)
    emit(
        {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message,
        }}
    )
    return 0

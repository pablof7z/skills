"""Codex and Claude hook handling for WorktreeGuard."""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any

from .audit import denial_message, denial_record
from .core import emit, resolve_path
from .operations import extract_operation, operation_cwd, payload_string, recover_codex_exec_workdir
from .policy import blocked_operation
from .storage import consume_valid_grant, load_hook_payload, write_denial


def cmd_hook_harness(args: argparse.Namespace) -> int:
    payload = load_hook_payload(sys.stdin.buffer.read())
    if args.harness == "codex":
        payload = recover_codex_exec_workdir(payload)
    return run_harness_hook(args.event, payload)


def run_harness_hook(event: str, payload: dict[str, Any]) -> int:
    if event not in {"pre-tool-use", "permission-request"}:
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
    if consume_valid_grant(blocked.base_path, session_id=session_id):
        return 0

    message = denial_message(blocked)
    write_denial(denial_record(event=event, payload=payload, operation=blocked))
    if event == "permission-request":
        emit(
            {"hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "deny", "message": message},
            }}
        )
    else:
        emit(
            {"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": message,
            }}
        )
    return 0

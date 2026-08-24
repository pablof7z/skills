"""Codex, Claude, and Grok hook handling for WorktreeGuard."""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any

from .audit import denial_message, denial_record, warn_message
from .core import emit, resolve_path
from .operations import extract_operation, operation_cwd, payload_string, recover_codex_exec_workdir
from .policy import blocked_operation, warned_operation
from .storage import consume_valid_grant, load_hook_payload, repo_config, write_denial

def emit_denial(harness: str, message: str) -> None:
    if harness == "grok":
        emit({"decision": "deny", "reason": message})
    else:
        emit({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message,
        }})


def cmd_hook_harness(args: argparse.Namespace) -> int:
    payload = load_hook_payload(sys.stdin.buffer.read())
    if args.harness == "codex":
        payload = recover_codex_exec_workdir(payload)
    return run_harness_hook(args.event, payload, harness=args.harness)


def run_harness_hook(
    event: str, payload: dict[str, Any], *, harness: str = "codex"
) -> int:
    if event != "pre-tool-use":
        return 0

    operation = extract_operation(payload)
    payload_cwd = resolve_path(
        str(payload.get("cwd") or payload.get("workspaceRoot") or os.getcwd())
    )
    cwd = operation_cwd(operation, payload_cwd)
    blocked = blocked_operation(operation, cwd)
    if blocked is not None:
        session_id = payload_string(
            payload, "session_id", "sessionId", "conversation_id", "conversationId",
            "thread_id", "threadId",
        )
        config = repo_config(blocked.base_path)
        bypass = config.policy(blocked.group).bypass
        if consume_valid_grant(
            blocked.base_path, session_id=session_id, group=blocked.group, bypass=bypass,
        ):
            return 0

        message = denial_message(blocked, config)
        write_denial(denial_record(event=event, payload=payload, operation=blocked))
        emit_denial(harness, message)
        return 0

    warned = warned_operation(operation, cwd)
    if warned is not None:
        message = warn_message(warned)
        if harness == "grok":
            emit({"decision": "allow", "reason": message})
        else:
            emit({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": message,
            }})
        sys.stderr.write(message + "\n")
    return 0

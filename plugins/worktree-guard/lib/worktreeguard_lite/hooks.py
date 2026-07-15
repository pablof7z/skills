"""Harness-agnostic hook dispatch and decisions."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Any

from .audit import (
    action_record,
    denial_message,
    log_action,
    write_action_log,
    write_denial_log,
)
from .branch_repair import repair_protected_base_branches
from .core import WorktreeGuardError, emit, path_contains, resolve_path
from .git import discover_repo
from .operations import (
    effective_operation_cwd,
    extract_operation,
    recover_codex_exec_workdir,
)
from .policy import operation_is_allowed, protected_write_target
from .repositories import protected_repo_for_path
from .sessions import (
    clear_session_cwd,
    record_session_cwd,
    stored_session_cwd,
)
from .storage import has_valid_grant, load_hook_payload


def cmd_hook_harness(args: argparse.Namespace) -> int:
    payload = load_hook_payload(sys.stdin.buffer.read())
    if args.harness == "codex":
        payload = recover_codex_exec_workdir(payload)
    return run_harness_hook(args.event, payload)


def run_harness_hook(event: str, payload: dict[str, Any]) -> int:
    if event == "session-start":
        return emit_session_context(payload)

    if event == "post-tool-use":
        record_session_cwd(payload)
        return 0

    if event == "stop":
        clear_session_cwd(payload)
        return 0

    if event not in {"pre-tool-use", "permission-request"}:
        return 0

    payload_cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    session_cwd = stored_session_cwd(payload) or payload_cwd
    operation = extract_operation(payload)
    cwd = effective_operation_cwd(operation, session_cwd)
    repair_protected_base_branches(event=event, payload=payload, operation=operation, cwd=cwd)

    write_target = protected_write_target(operation, cwd)
    if write_target is not None:
        base_path, protected = write_target
        if has_valid_grant(base_path):
            log_action(
                event=event,
                payload=payload,
                base_path=base_path,
                cwd=cwd,
                operation=operation,
                decision="allow",
                reason="grant_allowed",
                protected=protected,
            )
            return 0
        return deny_operation(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            protected=protected,
        )

    protected = protected_repo_for_path(cwd)
    if protected is None:
        log_action(
            event=event,
            payload=payload,
            base_path=None,
            cwd=cwd,
            operation=operation,
            decision="allow",
            reason="unprotected",
        )
        return 0

    base_path = resolve_path(str(protected["base_path"]))
    if not path_contains(base_path, cwd):
        log_action(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            decision="allow",
            reason="worktree_allowed",
            protected=protected,
        )
        return 0

    if operation_is_allowed(operation, cwd):
        log_action(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            decision="allow",
            reason="policy_allowed",
            protected=protected,
        )
        return 0

    if has_valid_grant(base_path):
        log_action(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=cwd,
            operation=operation,
            decision="allow",
            reason="grant_allowed",
            protected=protected,
        )
        return 0

    return deny_operation(
        event=event,
        payload=payload,
        base_path=base_path,
        cwd=cwd,
        operation=operation,
        protected=protected,
    )


def deny_operation(
    *,
    event: str,
    payload: dict[str, Any],
    base_path: Path,
    cwd: Path,
    operation: dict[str, Any],
    protected: dict[str, Any] | None,
) -> int:
    message = denial_message(base_path)
    record = action_record(
        event=event,
        payload=payload,
        base_path=base_path,
        cwd=cwd,
        operation=operation,
        decision="deny",
        reason="protected_base_mutation",
        protected=protected,
    )
    write_action_log(record)
    write_denial_log(record)
    if event == "permission-request":
        emit(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "deny", "message": message},
                }
            }
        )
    else:
        emit(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": message,
                }
            }
        )
    return 0


def emit_session_context(payload: dict[str, Any]) -> int:
    cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    protected = protected_repo_for_path(cwd)
    if protected is not None:
        base_path = resolve_path(str(protected["base_path"]))
        context = (
            "WorktreeGuard is active for this protected base checkout:\n"
            f"{base_path}\n\n"
            "Do mutating work from a Git worktree, not this protected base checkout."
        )
    else:
        try:
            repo = discover_repo(cwd)
        except WorktreeGuardError:
            context = "WorktreeGuard is installed. This directory is not in a Git repo."
        else:
            context = (
                "WorktreeGuard is active. This directory is a Git worktree for "
                "the protected base checkout:\n"
                f"{repo.base_path}\n\n"
                "Mutating work is allowed in this worktree."
            )
    emit({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}})
    return 0

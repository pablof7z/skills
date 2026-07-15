"""Session working-directory tracking."""

from __future__ import annotations

import os
import shlex
import time
from pathlib import Path
from typing import Any

from .core import path_contains, resolve_path
from .git import git_effective_cwd, git_worktree_add_path
from .operations import extract_operation
from .repositories import protected_repo_for_path
from .storage import load_state, save_state


def record_session_cwd(payload: dict[str, Any]) -> None:
    session_id = session_id_from_payload(payload)
    if not session_id:
        return
    payload_cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    previous_cwd = stored_session_cwd(payload) or payload_cwd
    operation = extract_operation(payload)
    next_cwd = cwd_from_pwd_response(operation, payload)
    if next_cwd is None:
        next_cwd = cwd_from_git_worktree_add(operation, previous_cwd)
    if next_cwd is None:
        return

    state = load_state()
    sessions = state.setdefault("sessions", {})
    if not isinstance(sessions, dict):
        sessions = {}
        state["sessions"] = sessions
    sessions[session_id] = {
        "cwd": str(next_cwd),
        "updated_at": int(time.time()),
    }
    save_state(state)


def clear_session_cwd(payload: dict[str, Any]) -> None:
    session_id = session_id_from_payload(payload)
    if not session_id:
        return
    state = load_state()
    sessions = state.get("sessions")
    if not isinstance(sessions, dict) or session_id not in sessions:
        return
    del sessions[session_id]
    save_state(state)


def stored_session_cwd(payload: dict[str, Any]) -> Path | None:
    session_id = session_id_from_payload(payload)
    if not session_id:
        return None
    state = load_state()
    sessions = state.get("sessions")
    if not isinstance(sessions, dict):
        return None
    session = sessions.get(session_id)
    if not isinstance(session, dict):
        return None
    raw_cwd = session.get("cwd")
    if not isinstance(raw_cwd, str) or not raw_cwd:
        return None
    return resolve_path(raw_cwd)


def session_id_from_payload(payload: dict[str, Any]) -> str:
    raw_session_id = (
        payload.get("session_id")
        or payload.get("sessionId")
        or payload.get("conversation_id")
        or payload.get("conversationId")
        or payload.get("thread_id")
        or payload.get("threadId")
    )
    return str(raw_session_id) if raw_session_id else ""


def cwd_from_pwd_response(operation: dict[str, Any], payload: dict[str, Any]) -> Path | None:
    command = operation.get("command")
    if not isinstance(command, str):
        return None
    try:
        parts = shlex.split(command.strip())
    except ValueError:
        return None
    if parts != ["pwd"]:
        return None
    response = payload.get("tool_response")
    if not isinstance(response, str):
        return None
    lines = [line.strip() for line in response.splitlines() if line.strip()]
    if len(lines) != 1:
        return None
    path = resolve_path(lines[0])
    return path if path.is_dir() else None


def cwd_from_git_worktree_add(operation: dict[str, Any], fallback: Path) -> Path | None:
    command = operation.get("command")
    if not isinstance(command, str):
        return None
    try:
        parts = shlex.split(command.strip())
    except ValueError:
        return None
    if not parts or Path(parts[0]).name != "git":
        return None
    git_cwd, git_args = git_effective_cwd(parts[1:], fallback)
    if len(git_args) < 2 or git_args[0] != "worktree" or git_args[1] != "add":
        return None
    target = git_worktree_add_path(git_args[2:])
    if target is None:
        return None
    target_path = resolve_path(target if target.is_absolute() else git_cwd / target)
    if not target_path.is_dir():
        return None
    protected = protected_repo_for_path(git_cwd)
    if protected is not None and path_contains(resolve_path(str(protected["base_path"])), target_path):
        return None
    return target_path

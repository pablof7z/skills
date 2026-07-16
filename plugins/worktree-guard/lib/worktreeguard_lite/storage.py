"""Durable state, grants, approval, and JSONL storage."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .core import (
    DEFAULT_ACTION_LOG_FILE,
    DEFAULT_DENY_LOG_FILE,
    Repo,
    WorktreeGuardError,
    resolve_path,
)


def write_jsonl_record(path: Path, record: dict[str, Any]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        return


def read_jsonl_records(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    records: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for line in lines:
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def load_hook_payload(stdin: bytes) -> dict[str, Any]:
    if not stdin.strip():
        return {}
    try:
        payload = json.loads(stdin.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def load_state() -> dict[str, Any]:
    path = state_path()
    if not path.is_file():
        return {"version": 1, "repos": {}, "worktrees": {}, "grants": [], "sessions": {}}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"version": 1, "repos": {}, "worktrees": {}, "grants": [], "sessions": {}}
    if not isinstance(payload, dict):
        return {"version": 1, "repos": {}, "worktrees": {}, "grants": [], "sessions": {}}
    payload.setdefault("version", 1)
    payload.setdefault("repos", {})
    payload.setdefault("worktrees", {})
    payload.setdefault("grants", [])
    payload.setdefault("sessions", {})
    return payload


def save_state(state: dict[str, Any]) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def request_human_approval(
    *,
    repo: "Repo",
    reason: str,
    requested_scope: str,
    timeout: int,
) -> str | None:
    override = os.environ.get("WTG_APPROVAL_RESPONSE")
    if override:
        normalized = override.strip().lower()
        if normalized in {"allow", "approve", "session"}:
            return "session" if requested_scope == "session" else "once"
        if normalized in {"once", "operation"}:
            return "once"
        return None

    if sys.platform != "darwin":
        return request_paired_laptop_approval(
            repo=repo,
            reason=reason,
            requested_scope=requested_scope,
            timeout=timeout,
        )

    prompt = (
        "The coding agent is requesting protected base checkout access.\n\n"
        f"Repo: {repo.base_path}\n"
        f"Branch: {repo.branch}\n"
        f"Scope requested: {requested_scope}\n\n"
        f"Reason:\n{reason}"
    )
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

    try:
        result = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout if timeout > 0 else None,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return request_paired_laptop_approval(
            repo=repo,
            reason=reason,
            requested_scope=requested_scope,
            timeout=timeout,
        )
    if result.returncode != 0:
        return request_paired_laptop_approval(
            repo=repo,
            reason=reason,
            requested_scope=requested_scope,
            timeout=timeout,
        )
    button = result.stdout.strip()
    if button == "Allow session":
        return "session"
    if button == "Allow once":
        return "once"
    return None


def request_paired_laptop_approval(
    *,
    repo: "Repo",
    reason: str,
    requested_scope: str,
    timeout: int,
) -> str | None:
    from .remote_approval import RemoteApprovalRequest, request_remote_approval

    request = RemoteApprovalRequest(
        operation="request-base-access",
        worktree=str(repo.worktree_path),
        repository=str(repo.base_path),
        reason=reason,
        session=os.environ.get("WTG_SESSION_ID", ""),
        ttl_seconds=DEFAULT_GRANT_TTL_SECONDS,
        requested_scope=requested_scope,
    )
    return request_remote_approval(
        request,
        wait_seconds=max(0, timeout),
        create_grant_on_allow=False,
    )


def create_grant(
    *,
    base_path: Path,
    scope: str,
    reason: str,
    ttl_seconds: int,
) -> dict[str, Any]:
    now = int(time.time())
    grant = {
        "id": f"grant-{now}-{os.getpid()}",
        "base_path": str(base_path),
        "scope": scope,
        "reason": reason,
        "created_at": now,
        "expires_at": now + max(1, ttl_seconds),
    }
    state = load_state()
    grants = state.setdefault("grants", [])
    if not isinstance(grants, list):
        grants = []
        state["grants"] = grants
    grants.append(grant)
    save_state(state)
    return grant


def has_valid_grant(base_path: Path) -> bool:
    state = load_state()
    now = int(time.time())
    changed = False
    for grant in state.get("grants", []):
        if not isinstance(grant, dict):
            continue
        if grant.get("base_path") != str(base_path):
            continue
        if int(grant.get("expires_at", 0)) <= now:
            continue
        if grant.get("revoked_at") is not None:
            continue
        scope = grant.get("scope")
        if scope == "session":
            return True
        if scope in {"once", "operation"} and grant.get("used_at") is None:
            grant["used_at"] = now
            changed = True
            save_state(state)
            return True
    if changed:
        save_state(state)
    return False


def active_grants(state: dict[str, Any]) -> list[dict[str, Any]]:
    now = int(time.time())
    result = []
    for grant in state.get("grants", []):
        if not isinstance(grant, dict):
            continue
        if int(grant.get("expires_at", 0)) <= now:
            continue
        if grant.get("revoked_at") is not None:
            continue
        if grant.get("scope") in {"once", "operation"} and grant.get("used_at") is not None:
            continue
        result.append(grant)
    return result


def apple_string(value: str) -> str:
    lines = value.splitlines() or [""]
    quoted_lines = [
        '"' + line.replace("\\", "\\\\").replace('"', '\\"') + '"'
        for line in lines
    ]
    return " & return & ".join(quoted_lines)


def state_path() -> Path:
    override = os.environ.get("WTG_STATE_FILE")
    if override:
        return resolve_path(override)
    return Path.home() / ".local" / "state" / "worktreeguard" / "lite-state.json"


def action_log_path() -> Path:
    override = os.environ.get("WTG_ACTION_LOG_FILE")
    if override:
        return resolve_path(override)
    return Path.home() / DEFAULT_ACTION_LOG_FILE


def deny_log_path() -> Path:
    override = os.environ.get("WTG_DENY_LOG_FILE")
    if override:
        return resolve_path(override)
    return Path.home() / DEFAULT_DENY_LOG_FILE


def stable_hook_shim_path(harness: str) -> Path:
    return Path.home() / ".local" / "bin" / f"wtg-hook-{harness}"

"""Preferences, local grants, and denial-log storage."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .core import DEFAULT_DENY_LOG_FILE, DEFAULT_GRANT_TTL_SECONDS, Repo, resolve_path


STATE_VERSION = 3
AUTO_GRANT_PREFERENCE = "auto_grant_base_edits"


def load_hook_payload(stdin: bytes) -> dict[str, Any]:
    try:
        payload = json.loads(stdin.decode("utf-8")) if stdin.strip() else {}
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def state_path() -> Path:
    override = os.environ.get("WTG_STATE_FILE")
    return resolve_path(override) if override else Path.home() / ".local/state/worktreeguard/state.json"


def deny_log_path() -> Path:
    override = os.environ.get("WTG_DENY_LOG_FILE")
    return resolve_path(override) if override else Path.home() / DEFAULT_DENY_LOG_FILE


def stable_hook_shim_path(harness: str) -> Path:
    return Path.home() / ".local/bin" / f"wtg-hook-{harness}"


def load_state() -> dict[str, Any]:
    try:
        payload = json.loads(state_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    grants = payload.get("grants", [])
    auto_grants = payload.get("auto_grants", [])
    preferences = payload.get("preferences", {})
    if not isinstance(preferences, dict):
        preferences = {}
    return {
        "version": STATE_VERSION,
        "grants": grants if isinstance(grants, list) else [],
        "auto_grants": auto_grants if isinstance(auto_grants, list) else [],
        "preferences": {
            AUTO_GRANT_PREFERENCE: bool(preferences.get(AUTO_GRANT_PREFERENCE, True)),
        },
    }


def save_state(state: dict[str, Any]) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    try:
        path.parent.chmod(0o700)
        temporary.chmod(0o600)
    except OSError:
        pass
    os.replace(temporary, path)


def create_grant(
    *, base_path: Path, scope: str, reason: str, ttl_seconds: int, session_id: str = ""
) -> dict[str, Any]:
    now = int(time.time())
    grant: dict[str, Any] = {
        "id": f"grant-{now}-{os.getpid()}",
        "base_path": str(resolve_path(base_path)),
        "scope": "once" if scope in {"once", "operation"} else "session",
        "reason": reason,
        "created_at": now,
        "expires_at": now + max(1, ttl_seconds),
    }
    if session_id:
        grant["session_id"] = session_id
    state = load_state()
    state["grants"].append(grant)
    save_state(state)
    return grant


def consume_valid_grant(base_path: Path, *, session_id: str = "") -> bool:
    state = load_state()
    now = int(time.time())
    active: list[dict[str, Any]] = []
    matched = False
    for grant in state["grants"]:
        if not isinstance(grant, dict) or int(grant.get("expires_at", 0)) <= now:
            continue
        grant_session = str(grant.get("session_id") or "")
        applies = (
            not matched
            and str(grant.get("base_path") or "") == str(resolve_path(base_path))
            and (not grant_session or grant_session == session_id)
        )
        if applies:
            matched = True
            if grant.get("scope") != "once":
                active.append(grant)
        else:
            active.append(grant)
    if active != state["grants"]:
        state["grants"] = active
        save_state(state)
    return matched


def active_grants() -> list[dict[str, Any]]:
    now = int(time.time())
    return [
        grant
        for grant in load_state()["grants"]
        if isinstance(grant, dict) and int(grant.get("expires_at", 0)) > now
    ]


def auto_grant_base_edits_enabled() -> bool:
    return bool(load_state()["preferences"][AUTO_GRANT_PREFERENCE])


def set_auto_grant_base_edits(enabled: bool) -> None:
    state = load_state()
    state["preferences"][AUTO_GRANT_PREFERENCE] = enabled
    if not enabled:
        state["auto_grants"] = []
    save_state(state)


def ensure_auto_grant(base_path: Path, *, session_id: str) -> bool:
    """Persist an edit-only auto grant and return whether it was newly created."""
    if not session_id:
        return True
    state = load_state()
    now = int(time.time())
    base = str(resolve_path(base_path))
    active = [
        grant for grant in state["auto_grants"]
        if isinstance(grant, dict) and int(grant.get("expires_at", 0)) > now
    ]
    if any(
        grant.get("base_path") == base and grant.get("session_id") == session_id
        for grant in active
    ):
        if active != state["auto_grants"]:
            state["auto_grants"] = active
            save_state(state)
        return False
    active.append({
        "base_path": base,
        "session_id": session_id,
        "created_at": now,
        "expires_at": now + DEFAULT_GRANT_TTL_SECONDS,
    })
    state["auto_grants"] = active
    save_state(state)
    return True


def active_auto_grants() -> list[dict[str, Any]]:
    now = int(time.time())
    return [
        grant for grant in load_state()["auto_grants"]
        if isinstance(grant, dict) and int(grant.get("expires_at", 0)) > now
    ]


def request_human_approval(*, repo: Repo, reason: str, requested_scope: str, timeout: int) -> str | None:
    override = os.environ.get("WTG_APPROVAL_RESPONSE", "").strip().lower()
    if override:
        if override in {"allow", "approve", "session"}:
            return "once" if requested_scope in {"once", "operation"} else "session"
        if override in {"once", "operation"}:
            return "once"
        return None
    if sys.platform != "darwin":
        return None
    prompt = (
        "Allow a coding agent to run a normally blocked Git command?\n\n"
        f"Base checkout: {repo.base_path}\nScope: {requested_scope}\n\nReason:\n{reason}"
    )
    escaped = prompt.replace("\\", "\\\\").replace('"', '\\"')
    script = (
        f'display dialog "{escaped}" buttons {{"Deny", "Allow once", "Allow session"}} '
        'default button "Deny" cancel button "Deny" with icon caution\nbutton returned of result'
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script], capture_output=True, text=True,
            timeout=timeout if timeout > 0 else None, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return {"Allow once": "once", "Allow session": "session"}.get(result.stdout.strip())


def write_denial(record: dict[str, Any]) -> None:
    path = deny_log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        pass


def read_denials() -> list[dict[str, Any]]:
    try:
        lines = deny_log_path().read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    records: list[dict[str, Any]] = []
    for line in lines:
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)
    return records

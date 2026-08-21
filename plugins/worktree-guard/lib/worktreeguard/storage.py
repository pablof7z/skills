"""Preferences, local grants, and denial-log storage."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .core import (
    DEFAULT_DENY_LOG_FILE, DEFAULT_GRANT_TTL_SECONDS, DEFAULT_REQUEST_LOG_FILE, Repo, resolve_path,
)


STATE_VERSION = 5
AUTO_GRANT_PREFERENCE = "auto_grant_base_edits"
REPO_MODES = "repo_modes"
VALID_REPO_MODES = frozenset({"full", "files-only", "off"})
DEFAULT_REPO_MODE = "full"


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


def request_log_path() -> Path:
    override = os.environ.get("WTG_REQUEST_LOG_FILE")
    return resolve_path(override) if override else Path.home() / DEFAULT_REQUEST_LOG_FILE


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
    if not isinstance(grants, list):
        grants = []
    preferences = payload.get("preferences", {})
    if not isinstance(preferences, dict):
        preferences = {}
    raw_repo_modes = payload.get(REPO_MODES, {})
    if not isinstance(raw_repo_modes, dict):
        raw_repo_modes = {}
    repo_modes = {
        str(path): mode
        for path, mode in raw_repo_modes.items()
        if isinstance(path, str) and mode in VALID_REPO_MODES
    }
    session_grants = [
        grant for grant in grants
        if isinstance(grant, dict)
        and grant.get("scope") == "session"
        and str(grant.get("session_id") or "")
    ]
    return {
        "version": STATE_VERSION,
        "grants": session_grants,
        "preferences": {
            AUTO_GRANT_PREFERENCE: bool(preferences.get(AUTO_GRANT_PREFERENCE, True)),
        },
        REPO_MODES: repo_modes,
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
    *, base_path: Path, reason: str, ttl_seconds: int, session_id: str
) -> dict[str, Any]:
    if not session_id:
        raise ValueError("session_id is required")
    now = int(time.time())
    grant: dict[str, Any] = {
        "id": f"grant-{now}-{os.getpid()}",
        "base_path": str(resolve_path(base_path)),
        "scope": "session",
        "reason": reason,
        "created_at": now,
        "expires_at": now + max(1, ttl_seconds),
        "session_id": session_id,
    }
    state = load_state()
    state["grants"].append(grant)
    save_state(state)
    return grant


def consume_valid_grant(base_path: Path, *, session_id: str = "") -> bool:
    if not session_id:
        return False
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
            and grant_session == session_id
        )
        if applies:
            matched = True
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
    save_state(state)


def repo_mode(base_path: Path) -> str:
    modes = load_state()[REPO_MODES]
    return modes.get(str(resolve_path(base_path)), DEFAULT_REPO_MODE)


def set_repo_mode(base_path: Path, mode: str) -> None:
    if mode not in VALID_REPO_MODES:
        raise ValueError(f"invalid guard mode: {mode!r}")
    state = load_state()
    state[REPO_MODES][str(resolve_path(base_path))] = mode
    save_state(state)


def all_repo_modes() -> dict[str, str]:
    return dict(load_state()[REPO_MODES])


def request_human_approval(*, repo: Repo, reason: str, timeout: int) -> bool:
    override = os.environ.get("WTG_APPROVAL_RESPONSE", "").strip().lower()
    if override:
        return override in {"allow", "approve", "session"}
    if sys.platform != "darwin":
        return False
    prompt = (
        "Allow a coding agent to run a normally blocked Git command?\n\n"
        f"Base checkout: {repo.base_path}\nScope: current harness session\n\nReason:\n{reason}"
    )
    escaped = prompt.replace("\\", "\\\\").replace('"', '\\"')
    script = (
        f'display dialog "{escaped}" buttons {{"Deny", "Allow session"}} '
        'default button "Deny" cancel button "Deny" with icon caution\nbutton returned of result'
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script], capture_output=True, text=True,
            timeout=timeout if timeout > 0 else None, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if result.returncode != 0:
        return False
    return result.stdout.strip() == "Allow session"


def write_denial(record: dict[str, Any]) -> None:
    _append_jsonl(deny_log_path(), record)


def read_denials() -> list[dict[str, Any]]:
    return _read_jsonl(deny_log_path())


def write_request(record: dict[str, Any]) -> None:
    _append_jsonl(request_log_path(), record)


def read_requests() -> list[dict[str, Any]]:
    return _read_jsonl(request_log_path())


def _append_jsonl(path: Path, record: dict[str, Any]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        pass


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
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

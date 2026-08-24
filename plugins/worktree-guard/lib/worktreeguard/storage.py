"""Local grants, denial logs, and per-repo ``.wtg.json`` configuration."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .core import (
    DEFAULT_DENY_LOG_FILE, DEFAULT_GRANT_TTL_SECONDS, DEFAULT_REQUEST_LOG_FILE, Repo,
    WorktreeGuardError, resolve_path,
)


STATE_VERSION = 7
CONFIG_FILENAME = ".wtg.json"
VALID_WRITE_MODES = frozenset({"block", "off", "warn"})
VALID_BRANCH_MODES = frozenset({"follow", "manual", "block"})


@dataclass(frozen=True)
class RepoConfig:
    enabled: bool
    writes: str
    allow_bypass: bool
    branch_changes: str


DEFAULT_CONFIG = RepoConfig(
    enabled=True, writes="block", allow_bypass=True, branch_changes="follow",
)


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
    session_grants = [
        grant for grant in grants
        if isinstance(grant, dict)
        and grant.get("scope") == "session"
        and str(grant.get("session_id") or "")
    ]
    return {"version": STATE_VERSION, "grants": session_grants}


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
    *, base_path: Path, reason: str, ttl_seconds: int, session_id: str, branch_change: bool = False,
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
        "branch_change": bool(branch_change),
    }
    state = load_state()
    state["grants"].append(grant)
    save_state(state)
    return grant


def consume_valid_grant(
    base_path: Path, *, session_id: str = "", needs_branch_change: bool = False,
) -> bool:
    """True if an active grant covers the requested operation for this session.

    ``needs_branch_change`` tightens coverage according to ``branchChanges``:
    ``block`` never, ``manual`` only a grant created via ``--branch-change``,
    ``follow`` any grant. Non-branch operations are covered by any grant.
    """
    if not session_id:
        return False
    config = repo_config(base_path) if needs_branch_change else None
    if config is not None and config.branch_changes == "block":
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
        if applies and needs_branch_change and config is not None and config.branch_changes == "manual":
            applies = bool(grant.get("branch_change"))
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


def config_path(base_path: Path) -> Path:
    return resolve_path(base_path) / CONFIG_FILENAME


def repo_config(base_path: Path) -> RepoConfig:
    """Load the per-repo ``.wtg.json`` from the base checkout root.

    Missing or malformed files fall back to the safe defaults per field.
    """
    try:
        data = json.loads(config_path(base_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return DEFAULT_CONFIG
    if not isinstance(data, dict):
        return DEFAULT_CONFIG
    writes = str(data.get("writes", DEFAULT_CONFIG.writes))
    if writes not in VALID_WRITE_MODES:
        writes = DEFAULT_CONFIG.writes
    branch_changes = str(data.get("branchChanges", DEFAULT_CONFIG.branch_changes))
    if branch_changes not in VALID_BRANCH_MODES:
        branch_changes = DEFAULT_CONFIG.branch_changes
    return RepoConfig(
        enabled=bool(data.get("enabled", DEFAULT_CONFIG.enabled)),
        writes=writes,
        allow_bypass=bool(data.get("allowBypass", DEFAULT_CONFIG.allow_bypass)),
        branch_changes=branch_changes,
    )


def read_config(base_path: Path) -> dict[str, Any]:
    """Return the effective config as a JSON-serializable mapping."""
    config = repo_config(base_path)
    return {
        "enabled": config.enabled,
        "writes": config.writes,
        "allowBypass": config.allow_bypass,
        "branchChanges": config.branch_changes,
    }


def write_config(base_path: Path, config: dict[str, Any]) -> None:
    path = config_path(base_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def set_config_value(base_path: Path, key: str, value: Any) -> dict[str, Any]:
    if key not in {"enabled", "writes", "allowBypass", "branchChanges"}:
        raise WorktreeGuardError(f"unknown config key: {key!r}")
    config = read_config(base_path)
    config[key] = normalize_config_value(key, value)
    write_config(base_path, config)
    return config


def normalize_config_value(key: str, value: Any) -> Any:
    if key == "writes":
        text = str(value).lower()
        if text not in VALID_WRITE_MODES:
            raise WorktreeGuardError(
                f"invalid writes value: {value!r} (expected block, off, or warn)"
            )
        return text
    if key == "branchChanges":
        text = str(value).lower()
        if text not in VALID_BRANCH_MODES:
            raise WorktreeGuardError(
                f"invalid branchChanges value: {value!r} (expected follow, manual, or block)"
            )
        return text
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text in {"true", "on", "yes", "1"}:
        return True
    if text in {"false", "off", "no", "0"}:
        return False
    raise WorktreeGuardError(f"invalid boolean value for {key}: {value!r}")


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
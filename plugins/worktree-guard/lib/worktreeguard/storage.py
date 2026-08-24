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
    DEFAULT_DENY_LOG_FILE, DEFAULT_GRANT_TTL_SECONDS, DEFAULT_REQUEST_LOG_FILE, GUARD_GROUPS, Repo,
    WorktreeGuardError, resolve_path,
)


STATE_VERSION = 8
CONFIG_FILENAME = ".wtg.json"
VALID_DISPOSITIONS = frozenset({"allow", "warn", "block"})
VALID_BYPASS = frozenset({"auto", "manual", "none"})

# Legacy (pre-group) shapes, still read from an old-format .wtg.json and upgraded
# on the fly: "writes"/"branchChanges" as bare strings, plus a top-level
# "allowBypass" boolean that used to be the single global bypass switch for every
# blocked-by-default surface. write_config always saves the new nested shape, so
# these only ever apply on read.
_LEGACY_WRITES_DISPOSITION = {"block": "block", "warn": "warn", "off": "allow"}
# value -> (disposition, bypass override or None to defer to legacy allowBypass)
_LEGACY_BRANCH_CHANGES = {
    "follow": ("block", None),
    "manual": ("block", "manual"),
    "block": ("block", "none"),
}


@dataclass(frozen=True)
class GroupPolicy:
    """The two independent axes that govern one guard group.

    ``disposition`` is what happens by default: ``allow`` (silent), ``warn``
    (allowed, but a nudge is injected) or ``block`` (refused until a grant covers
    it). ``bypass`` only matters when ``disposition == "block"``: ``auto`` means
    ``wtg request-base-access --group <name>`` is granted automatically (with a
    local notification), ``manual`` means it blocks until a human approves via the
    local dialog, ``none`` means it can never be granted at all — only a linked
    worktree gets you out of it.
    """

    disposition: str
    bypass: str


DEFAULT_GROUP_POLICY = GroupPolicy(disposition="block", bypass="auto")

# Maps the four GUARD_GROUPS names (the ``.wtg.json``/CLI spelling) to their
# RepoConfig attribute (snake_case, since "branchChanges" isn't a valid identifier).
_ATTR_BY_GROUP = {
    "writes": "writes",
    "branchChanges": "branch_changes",
    "discard": "discard",
    "stash": "stash",
}


@dataclass(frozen=True)
class RepoConfig:
    enabled: bool
    writes: GroupPolicy
    branch_changes: GroupPolicy
    discard: GroupPolicy
    stash: GroupPolicy

    def policy(self, group: str) -> GroupPolicy:
        """Look up one group's policy by its ``.wtg.json``/CLI name."""
        return getattr(self, _ATTR_BY_GROUP[group])


DEFAULT_CONFIG = RepoConfig(
    enabled=True,
    writes=DEFAULT_GROUP_POLICY,
    branch_changes=DEFAULT_GROUP_POLICY,
    discard=DEFAULT_GROUP_POLICY,
    stash=DEFAULT_GROUP_POLICY,
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
    *, base_path: Path, reason: str, ttl_seconds: int, session_id: str, group: str | None = None,
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
        # None = a general-purpose grant: covers any group whose bypass is "auto",
        # never one whose bypass is "manual" (that needs the exact group tag).
        "group": group,
    }
    state = load_state()
    state["grants"].append(grant)
    save_state(state)
    return grant


def consume_valid_grant(base_path: Path, *, session_id: str, group: str, bypass: str) -> bool:
    """True if an active grant covers ``group`` (whose configured bypass mode is
    ``bypass``) for this session.

    ``none`` is never satisfiable. ``manual`` only a grant explicitly requested for
    this exact ``group`` (``wtg request-base-access --group <name>``). ``auto`` any
    live grant for this base_path/session, tagged or not.
    """
    if not session_id or bypass == "none":
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
        if applies and bypass == "manual":
            applies = grant.get("group") == group
        if applies:
            matched = True
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

    Missing or malformed files fall back to the safe defaults per field. Old-format
    keys (bare-string ``writes``/``branchChanges``, a top-level ``allowBypass``) are
    transparently upgraded; ``write_config`` always saves the new nested shape, so
    a repo only ever sees the old shape once, on its first read after upgrading.
    """
    try:
        data = json.loads(config_path(base_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return DEFAULT_CONFIG
    if not isinstance(data, dict):
        return DEFAULT_CONFIG
    return RepoConfig(
        enabled=bool(data.get("enabled", DEFAULT_CONFIG.enabled)),
        writes=_group_policy(data, "writes"),
        branch_changes=_group_policy(data, "branchChanges"),
        discard=_group_policy(data, "discard"),
        stash=_group_policy(data, "stash"),
    )


def _group_policy(data: dict[str, Any], group: str) -> GroupPolicy:
    raw = data.get(group)
    legacy_bypass = _legacy_bypass_default(data)
    if isinstance(raw, dict):
        disposition = str(raw.get("disposition", DEFAULT_GROUP_POLICY.disposition))
        if disposition not in VALID_DISPOSITIONS:
            disposition = DEFAULT_GROUP_POLICY.disposition
        bypass = str(raw.get("bypass", legacy_bypass))
        if bypass not in VALID_BYPASS:
            bypass = legacy_bypass
        return GroupPolicy(disposition, bypass)
    if isinstance(raw, str):
        if group == "writes":
            disposition = _LEGACY_WRITES_DISPOSITION.get(raw, DEFAULT_GROUP_POLICY.disposition)
            return GroupPolicy(disposition, legacy_bypass)
        if group == "branchChanges":
            disposition, override = _LEGACY_BRANCH_CHANGES.get(
                raw, (DEFAULT_GROUP_POLICY.disposition, None)
            )
            return GroupPolicy(disposition, override or legacy_bypass)
    # Absent — or "discard"/"stash", which never had a legacy scalar form of their
    # own and always implicitly followed the single legacy allowBypass switch.
    return GroupPolicy(DEFAULT_GROUP_POLICY.disposition, legacy_bypass)


def _legacy_bypass_default(data: dict[str, Any]) -> str:
    if "allowBypass" in data:
        return "auto" if bool(data["allowBypass"]) else "manual"
    return DEFAULT_GROUP_POLICY.bypass


def read_config(base_path: Path) -> dict[str, Any]:
    """Return the effective configuration as a JSON-serializable mapping."""
    return _config_dict(repo_config(base_path))


def default_config() -> dict[str, Any]:
    """The new-format config `config init` writes for a repo with no file yet."""
    return _config_dict(DEFAULT_CONFIG)


def _config_dict(config: RepoConfig) -> dict[str, Any]:
    return {
        "enabled": config.enabled,
        "writes": _policy_dict(config.writes),
        "branchChanges": _policy_dict(config.branch_changes),
        "discard": _policy_dict(config.discard),
        "stash": _policy_dict(config.stash),
    }


def _policy_dict(policy: GroupPolicy) -> dict[str, str]:
    return {"disposition": policy.disposition, "bypass": policy.bypass}


def write_config(base_path: Path, config: dict[str, Any]) -> None:
    path = config_path(base_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def set_config_value(base_path: Path, key: str, value: Any) -> dict[str, Any]:
    """Set one leaf of the effective config and write it back in the new shape.

    ``key`` is either ``enabled`` or ``<group>.disposition``/``<group>.bypass``
    for a group in :data:`worktreeguard.core.GUARD_GROUPS`.
    """
    config = read_config(base_path)
    if key == "enabled":
        config["enabled"] = normalize_bool(value)
        write_config(base_path, config)
        return config
    group, separator, field = key.partition(".")
    if not separator or group not in GUARD_GROUPS or field not in ("disposition", "bypass"):
        raise WorktreeGuardError(
            f"unknown config key: {key!r} (expected 'enabled' or "
            f"'<group>.disposition'/'<group>.bypass', group one of "
            f"{', '.join(GUARD_GROUPS)})"
        )
    config[group][field] = normalize_group_value(field, value)
    write_config(base_path, config)
    return config


def normalize_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text in {"true", "on", "yes", "1"}:
        return True
    if text in {"false", "off", "no", "0"}:
        return False
    raise WorktreeGuardError(f"invalid boolean value: {value!r}")


def normalize_group_value(field: str, value: Any) -> str:
    text = str(value).strip().lower()
    valid = VALID_DISPOSITIONS if field == "disposition" else VALID_BYPASS
    if text not in valid:
        raise WorktreeGuardError(
            f"invalid {field} value: {value!r} (expected one of {', '.join(sorted(valid))})"
        )
    return text


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

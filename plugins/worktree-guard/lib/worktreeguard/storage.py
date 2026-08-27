"""Local grants, denial logs, and per-repo ``.wtg.json`` configuration."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any

from .core import (
    ACCESS_SCOPES, DEFAULT_DENY_LOG_FILE, DEFAULT_REQUEST_LOG_FILE, GUARD_GROUPS, Repo,
    WorktreeGuardError, resolve_path,
)


STATE_VERSION = 9
CONFIG_FILENAME = ".wtg.json"
VALID_DISPOSITIONS = frozenset({"allow", "warn", "block"})
VALID_BYPASS = frozenset({"auto", "manual", "none"})


@dataclass(frozen=True)
class GroupPolicy:
    """The settings that govern one guard group.

    ``disposition`` is what happens by default: ``allow`` (silent), ``warn``
    (allowed, but a nudge is injected) or ``block`` (refused until a grant covers
    it). ``bypass`` only matters when ``disposition == "block"``: ``auto`` means
    ``wtg request-base-access --scope <name>`` is granted automatically (with a
    local notification), ``manual`` means it blocks until a human approves via the
    local dialog, ``none`` means it can never be granted at all — only a linked
    worktree gets you out of it. ``message`` optionally replaces the entire
    agent-visible message when this policy is triggered; ``None`` retains the
    built-in contextual message.
    """

    disposition: str
    bypass: str
    message: str | None = None


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


class ApprovalOutcome(str, Enum):
    APPROVED = "approved"
    REJECTED = "rejected"
    TIMED_OUT = "timed_out"


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


def load_state() -> dict[str, Any]:
    try:
        payload = json.loads(state_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    if payload.get("version") != STATE_VERSION:
        return {"version": STATE_VERSION, "grants": []}
    grants = payload.get("grants", [])
    if not isinstance(grants, list):
        grants = []
    session_grants = [
        grant for grant in grants
        if isinstance(grant, dict)
        and str(grant.get("session_id") or "")
        and str(grant.get("scope") or "") in ACCESS_SCOPES
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
    *, base_path: Path, reason: str, session_id: str, scope: str,
    iterm_session_id: str = "",
) -> dict[str, Any]:
    if not session_id:
        raise ValueError("session_id is required")
    if scope not in ACCESS_SCOPES:
        raise ValueError(f"unknown access scope: {scope!r}")
    now = int(time.time())
    grant: dict[str, Any] = {
        "id": f"grant-{now}-{os.getpid()}",
        "base_path": str(resolve_path(base_path)),
        "scope": scope,
        "reason": reason,
        "created_at": now,
        "session_id": session_id,
        # The iTerm2 tab this grant was requested from, if any — lets the
        # notification toast jump back to it. Empty when not running in iTerm2.
        "iterm_session_id": iterm_session_id,
    }
    state = load_state()
    state["grants"].append(grant)
    save_state(state)
    return grant


def consume_valid_grant(base_path: Path, *, session_id: str, scope: str, bypass: str) -> bool:
    """True if a session grant covers ``scope`` (whose configured bypass mode is
    ``bypass``) for this session.

    ``none`` is never satisfiable. ``manual`` only a grant explicitly requested for
    this exact scope. ``auto`` accepts any grant for this base path/session.
    """
    if not session_id or bypass == "none":
        return False
    state = load_state()
    matched = False
    for grant in state["grants"]:
        if not isinstance(grant, dict):
            continue
        grant_session = str(grant.get("session_id") or "")
        applies = (
            not matched
            and str(grant.get("base_path") or "") == str(resolve_path(base_path))
            and grant_session == session_id
        )
        if applies and bypass == "manual":
            applies = grant.get("scope") == scope
        if applies:
            matched = True
    return matched


def revoke_grants(
    base_path: Path, *, session_id: str | None = None, grant_id: str | None = None,
) -> int:
    """Remove live grants for ``base_path``.

    ``grant_id`` scopes to exactly one grant (what the notification toast's
    revoke control uses, so revoking one auto-granted request never touches a
    sibling grant for a different access scope in the same session). Without it,
    every grant for ``base_path`` is removed, optionally narrowed to one
    ``session_id`` — the coarse form the bare ``wtg revoke`` CLI uses.

    Returns the number of grants removed.
    """
    state = load_state()
    target = str(resolve_path(base_path))
    kept: list[dict[str, Any]] = []
    removed = 0
    for grant in state["grants"]:
        matches = (
            isinstance(grant, dict)
            and str(grant.get("base_path") or "") == target
            and (session_id is None or str(grant.get("session_id") or "") == session_id)
            and (grant_id is None or str(grant.get("id") or "") == grant_id)
        )
        if matches:
            removed += 1
        else:
            kept.append(grant)
    if removed:
        state["grants"] = kept
        save_state(state)
    return removed


def active_grants() -> list[dict[str, Any]]:
    return list(load_state()["grants"])


def config_path(base_path: Path) -> Path:
    return resolve_path(base_path) / CONFIG_FILENAME


def global_config_path() -> Path:
    """Path to the home-directory-wide fallback config.

    Overridable via ``WTG_GLOBAL_CONFIG_FILE`` for testing.
    """
    override = os.environ.get("WTG_GLOBAL_CONFIG_FILE")
    return resolve_path(override) if override else Path.home() / ".config" / "worktreeguard" / "config.json"


def repo_config(base_path: Path) -> RepoConfig:
    """Load the per-repo ``.wtg.json`` from the base checkout root.

    Falls back to the global home-directory config (``~/.config/worktreeguard/config.json``)
    when the repo has no local file (or the file is unreadable/malformed), then to
    hard-coded defaults.
    """
    for path_fn in (lambda: config_path(base_path), global_config_path):
        try:
            data = json.loads(path_fn().read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(data, dict):
            continue
        return RepoConfig(
            enabled=bool(data.get("enabled", DEFAULT_CONFIG.enabled)),
            writes=_group_policy(data, "writes"),
            branch_changes=_group_policy(data, "branchChanges"),
            discard=_group_policy(data, "discard"),
            stash=_group_policy(data, "stash"),
        )
    return DEFAULT_CONFIG


def _group_policy(data: dict[str, Any], group: str) -> GroupPolicy:
    raw = data.get(group)
    if isinstance(raw, dict):
        disposition = str(raw.get("disposition", DEFAULT_GROUP_POLICY.disposition))
        if disposition not in VALID_DISPOSITIONS:
            disposition = DEFAULT_GROUP_POLICY.disposition
        bypass = str(raw.get("bypass", DEFAULT_GROUP_POLICY.bypass))
        if bypass not in VALID_BYPASS:
            bypass = DEFAULT_GROUP_POLICY.bypass
        message = raw.get("message")
        if not isinstance(message, str) or not message.strip():
            message = None
        return GroupPolicy(disposition, bypass, message)
    return DEFAULT_GROUP_POLICY


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
    result = {"disposition": policy.disposition, "bypass": policy.bypass}
    if policy.message is not None:
        result["message"] = policy.message
    return result


def write_config(base_path: Path, config: dict[str, Any]) -> None:
    path = config_path(base_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def set_config_value(base_path: Path, key: str, value: Any) -> dict[str, Any]:
    """Set one leaf of the effective config and write it back in the new shape.

    ``key`` is either ``enabled`` or a ``<policy>.disposition``,
    ``<policy>.bypass``, or ``<policy>.message`` leaf for a policy key in
    :data:`worktreeguard.core.GUARD_GROUPS`.
    """
    config = read_config(base_path)
    if key == "enabled":
        config["enabled"] = normalize_bool(value)
        write_config(base_path, config)
        return config
    policy_key, separator, field = key.partition(".")
    if not separator or policy_key not in GUARD_GROUPS or field not in (
        "disposition", "bypass", "message",
    ):
        raise WorktreeGuardError(
            f"unknown config key: {key!r} (expected 'enabled' or "
            f"'<policy>.disposition'/'<policy>.bypass'/'<policy>.message', policy one of "
            f"{', '.join(GUARD_GROUPS)})"
        )
    if field == "message":
        message = normalize_policy_message(value)
        if message is None:
            config[policy_key].pop("message", None)
        else:
            config[policy_key]["message"] = message
    else:
        config[policy_key][field] = normalize_group_value(field, value)
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


def normalize_policy_message(value: Any) -> str | None:
    """An empty CLI value clears the override and restores the default message."""
    if not isinstance(value, str):
        raise WorktreeGuardError("policy message must be a string")
    return value if value.strip() else None


def request_human_approval(
    *, repo: Repo, reason: str, scope: str, timeout: int,
) -> ApprovalOutcome:
    override = os.environ.get("WTG_APPROVAL_RESPONSE", "").strip().lower()
    if override:
        if override in {"allow", "approve", "session"}:
            return ApprovalOutcome.APPROVED
        if override in {"timeout", "timed_out"}:
            return ApprovalOutcome.TIMED_OUT
        return ApprovalOutcome.REJECTED
    if sys.platform != "darwin":
        return ApprovalOutcome.REJECTED

    from .install import toast_binary_path
    toast = toast_binary_path()
    if toast.is_file():
        return _approve_via_toast(toast, repo=repo, reason=reason, scope=scope, timeout=timeout)
    return _approve_via_dialog(repo=repo, reason=reason, timeout=timeout)


def _approve_via_toast(
    toast: Path, *, repo: Repo, reason: str, scope: str, timeout: int,
) -> ApprovalOutcome:
    from .notifications import iterm_focus_command
    try:
        result = subprocess.run(
            [
                str(toast), repo.base_path.name, scope, "1", reason,
                str(timeout), iterm_focus_command() or "", "",
            ],
            capture_output=True, text=True,
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ApprovalOutcome.TIMED_OUT
    return _approval_outcome(result.stdout.strip())


def _approve_via_dialog(*, repo: Repo, reason: str, timeout: int) -> ApprovalOutcome:
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
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ApprovalOutcome.TIMED_OUT
    if result.returncode != 0:
        return ApprovalOutcome.REJECTED
    return ApprovalOutcome.APPROVED if result.stdout.strip() == "Allow session" else ApprovalOutcome.REJECTED


def _approval_outcome(raw: str) -> ApprovalOutcome:
    if raw == "approve":
        return ApprovalOutcome.APPROVED
    if raw == "timeout":
        return ApprovalOutcome.TIMED_OUT
    return ApprovalOutcome.REJECTED


def write_denial(record: dict[str, Any]) -> None:
    _append_jsonl(deny_log_path(), record)


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

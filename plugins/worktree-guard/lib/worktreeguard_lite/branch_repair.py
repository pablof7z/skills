"""Watcher-lite repair of protected base branches."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

from .audit import action_record, write_action_log
from .core import resolve_path
from .git import (
    git_output_optional,
    git_status_is_clean,
    local_branch_exists,
)
from .repositories import protected_repo_for_path
from .storage import load_state


def repair_protected_base_branches(
    *,
    event: str,
    payload: dict[str, Any],
    operation: dict[str, Any],
    cwd: Path,
) -> None:
    seen: set[Path] = set()
    state = load_state()
    for repo in state.get("repos", {}).values():
        if not isinstance(repo, dict):
            continue
        raw_base_path = repo.get("base_path")
        if not isinstance(raw_base_path, str) or not raw_base_path:
            continue
        base_path = resolve_path(raw_base_path)
        if base_path in seen:
            continue
        seen.add(base_path)
        repair_protected_base_branch(
            event=event,
            payload=payload,
            operation=operation,
            base_path=base_path,
            protected=repo,
        )

    protected = protected_repo_for_path(cwd)
    if protected is None:
        return
    raw_base_path = protected.get("base_path")
    if not isinstance(raw_base_path, str) or not raw_base_path:
        return
    base_path = resolve_path(raw_base_path)
    if base_path in seen:
        return
    repair_protected_base_branch(
        event=event,
        payload=payload,
        operation=operation,
        base_path=base_path,
        protected=protected,
    )


def repair_protected_base_branch(
    *,
    event: str,
    payload: dict[str, Any],
    operation: dict[str, Any],
    base_path: Path,
    protected: dict[str, Any],
) -> None:
    if not base_path.is_dir():
        return

    target_branch = default_branch_for_base(base_path, protected)
    current_branch = git_output_optional(base_path, "branch", "--show-current")
    if target_branch is None:
        log_branch_repair(
            event=event,
            payload=payload,
            operation=operation,
            base_path=base_path,
            protected=protected,
            decision="repair_failed",
            reason="base_branch_default_unknown",
            current_branch=current_branch,
            target_branch="",
        )
        return
    if current_branch == target_branch:
        return
    if not git_status_is_clean(base_path):
        log_branch_repair(
            event=event,
            payload=payload,
            operation=operation,
            base_path=base_path,
            protected=protected,
            decision="repair_failed",
            reason="base_branch_dirty",
            current_branch=current_branch,
            target_branch=target_branch,
        )
        return

    result = subprocess.run(
        ["git", "switch", target_branch],
        cwd=str(base_path),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        log_branch_repair(
            event=event,
            payload=payload,
            operation=operation,
            base_path=base_path,
            protected=protected,
            decision="repair",
            reason="base_branch_restored",
            current_branch=current_branch,
            target_branch=target_branch,
        )
        return

    log_branch_repair(
        event=event,
        payload=payload,
        operation=operation,
        base_path=base_path,
        protected=protected,
        decision="repair_failed",
        reason="base_branch_switch_failed",
        current_branch=current_branch,
        target_branch=target_branch,
        error=(result.stderr.strip() or result.stdout.strip()),
    )


def default_branch_for_base(base_path: Path, protected: dict[str, Any]) -> str | None:
    remotes = ["origin"]
    remote_output = git_output_optional(base_path, "remote")
    for remote in remote_output.splitlines():
        remote = remote.strip()
        if remote and remote not in remotes:
            remotes.append(remote)
    for remote in remotes:
        raw = git_output_optional(base_path, "symbolic-ref", "--quiet", "--short", f"refs/remotes/{remote}/HEAD")
        prefix = f"{remote}/"
        if raw.startswith(prefix):
            return raw.removeprefix(prefix)

    protected_branch = str(protected.get("branch") or "")
    if protected_branch and protected_branch != "HEAD":
        return protected_branch

    for branch in ("main", "master"):
        if local_branch_exists(base_path, branch):
            return branch
    return None


def log_branch_repair(
    *,
    event: str,
    payload: dict[str, Any],
    operation: dict[str, Any],
    base_path: Path,
    protected: dict[str, Any],
    decision: str,
    reason: str,
    current_branch: str,
    target_branch: str,
    error: str = "",
) -> None:
    write_action_log(
        action_record(
            event=event,
            payload=payload,
            base_path=base_path,
            cwd=base_path,
            operation=operation,
            decision=decision,
            reason=reason,
            protected=protected,
            extra={
                "current_branch": current_branch,
                "target_branch": target_branch,
                "error": error,
            },
        )
    )

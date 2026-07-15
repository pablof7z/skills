"""Protected-repository discovery and validation."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .core import WorktreeGuardError, path_contains, resolve_path
from .git import discover_repo, git_main_worktree_matches
from .storage import load_state


def protected_repo_for_path(path: Path) -> dict[str, Any] | None:
    path = resolve_path(path)
    env_base = os.environ.get("WTG_PROTECTED_BASE")
    if env_base:
        base = resolve_path(env_base)
        if path_contains(base, path) and git_main_worktree_matches(base, path):
            return {
                "base_path": str(base),
            }

    env_worktree = os.environ.get("WTG_WORKTREE_PATH")
    if env_worktree and path_contains(resolve_path(env_worktree), path):
        return None

    state = load_state()
    for repo in state.get("repos", {}).values():
        protected = validated_protected_repo(repo, path)
        if protected is not None:
            return protected

    try:
        repo = discover_repo(path)
    except WorktreeGuardError:
        return None
    marker = repo.base_path / ".wtg.toml"
    if marker.is_file() and repo.worktree_path == repo.base_path and path_contains(repo.base_path, path):
        return {
            "base_path": str(repo.base_path),
            "common_git_dir": str(repo.common_git_dir),
            "branch": repo.branch,
            "head": repo.head,
        }
    if repo.worktree_path == repo.base_path and path_contains(repo.base_path, path):
        return {
            "base_path": str(repo.base_path),
            "common_git_dir": str(repo.common_git_dir),
            "branch": repo.branch,
            "head": repo.head,
            "default_protected": True,
        }
    return None


def validated_protected_repo(repo: Any, path: Path) -> dict[str, Any] | None:
    if not isinstance(repo, dict):
        return None
    raw_base_path = repo.get("base_path")
    if not isinstance(raw_base_path, str) or not raw_base_path:
        return None
    base_path = resolve_path(raw_base_path)
    if not path_contains(base_path, path):
        return None
    if not git_main_worktree_matches(base_path, path):
        return None
    protected = dict(repo)
    protected["base_path"] = str(base_path)
    return protected

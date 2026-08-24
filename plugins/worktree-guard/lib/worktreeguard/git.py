"""Minimal Git repository discovery used by the guard."""

from __future__ import annotations

import subprocess
from pathlib import Path

from .core import Repo, WorktreeGuardError, resolve_path


def git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or "not a Git repository"
        raise WorktreeGuardError(message)
    return result


def discover_repo(path: Path) -> Repo:
    cwd = resolve_path(path)
    worktree = resolve_path(git(cwd, "rev-parse", "--show-toplevel").stdout.strip())
    base = main_worktree(worktree) or worktree
    branch = git(cwd, "branch", "--show-current").stdout.strip() or "HEAD"
    head = git(cwd, "rev-parse", "HEAD").stdout.strip()
    return Repo(base_path=base, worktree_path=worktree, branch=branch, head=head)


def main_worktree(cwd: Path) -> Path | None:
    result = subprocess.run(
        ["git", "worktree", "list", "--porcelain"],
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            return resolve_path(line.removeprefix("worktree "))
    return None


def is_main_worktree(path: Path) -> tuple[bool, Repo | None]:
    try:
        repo = discover_repo(path)
    except (OSError, WorktreeGuardError):
        return False, None
    return repo.worktree_path == repo.base_path, repo


def is_ref(cwd: Path, name: str) -> bool:
    """True if ``name`` resolves to a Git revision (branch/commit/tag)."""
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", name],
        cwd=str(cwd), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, check=False,
    )
    return result.returncode == 0

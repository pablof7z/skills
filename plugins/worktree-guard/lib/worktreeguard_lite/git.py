"""Git command parsing and repository discovery."""

from __future__ import annotations

import shlex
import subprocess
from pathlib import Path

from .core import Repo, WorktreeGuardError, resolve_path


def git_command_cwd(command: Any, cwd: Path) -> Path | None:
    if not isinstance(command, str) or not command.strip():
        return None
    try:
        parts = shlex.split(command.strip())
    except ValueError:
        return None
    if not parts or Path(parts[0]).name != "git":
        return None
    git_cwd, _ = git_effective_cwd(parts[1:], cwd)
    return git_cwd


def git_effective_cwd(args: list[str], cwd: Path) -> tuple[Path, list[str]]:
    remaining = list(args)
    effective_cwd = cwd
    while remaining:
        arg = remaining[0]
        if arg == "-C":
            if len(remaining) < 2:
                return effective_cwd, remaining
            raw_path = Path(remaining[1]).expanduser()
            effective_cwd = resolve_path(raw_path if raw_path.is_absolute() else effective_cwd / raw_path)
            remaining = remaining[2:]
            continue
        if arg.startswith("-C") and len(arg) > 2:
            raw_path = Path(arg[2:]).expanduser()
            effective_cwd = resolve_path(raw_path if raw_path.is_absolute() else effective_cwd / raw_path)
            remaining = remaining[1:]
            continue
        if arg == "--work-tree":
            if len(remaining) < 2:
                return effective_cwd, remaining
            raw_path = Path(remaining[1]).expanduser()
            effective_cwd = resolve_path(raw_path if raw_path.is_absolute() else effective_cwd / raw_path)
            remaining = remaining[2:]
            continue
        if arg.startswith("--work-tree="):
            raw_path = Path(arg.partition("=")[2]).expanduser()
            effective_cwd = resolve_path(raw_path if raw_path.is_absolute() else effective_cwd / raw_path)
            remaining = remaining[1:]
            continue
        if arg in {"-c", "--config-env", "--exec-path", "--git-dir", "--namespace"}:
            if len(remaining) < 2:
                return effective_cwd, remaining
            remaining = remaining[2:]
            continue
        if any(arg.startswith(f"{option}=") for option in ("--config-env", "--exec-path", "--git-dir", "--namespace")):
            remaining = remaining[1:]
            continue
        if arg in {"--no-pager", "--paginate", "--bare", "--version", "--help", "--no-optional-locks"}:
            remaining = remaining[1:]
            continue
        break
    return effective_cwd, remaining


def git_worktree_add_path(args: list[str]) -> Path | None:
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"-b", "-B", "--reason"}:
            index += 2
            continue
        if arg.startswith(("-b", "-B")) and len(arg) > 2:
            index += 1
            continue
        if arg.startswith("--reason="):
            index += 1
            continue
        if arg.startswith("-") and arg != "-":
            index += 1
            continue
        return Path(arg)
    return None


def git_main_worktree_matches(base_path: Path, path: Path) -> bool:
    try:
        repo = discover_repo(path)
    except WorktreeGuardError:
        return False
    return repo.base_path == base_path and repo.worktree_path == base_path


def local_branch_exists(base_path: Path, branch: str) -> bool:
    result = subprocess.run(
        ["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        cwd=str(base_path),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    return result.returncode == 0


def git_status_is_clean(base_path: Path) -> bool:
    result = subprocess.run(
        ["git", "status", "--porcelain=v1", "-z"],
        cwd=str(base_path),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=False,
        check=False,
    )
    return result.returncode == 0 and result.stdout == b""


def git_output_optional(base_path: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=str(base_path),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def discover_repo(path: Path) -> "Repo":
    path = resolve_path(path)
    worktree_path = resolve_path(git(path, "rev-parse", "--show-toplevel").stdout.strip())
    raw_common_git_dir = Path(git(path, "rev-parse", "--git-common-dir").stdout.strip())
    common_git_dir = raw_common_git_dir if raw_common_git_dir.is_absolute() else path / raw_common_git_dir
    branch_result = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=str(path),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    branch = branch_result.stdout.strip() or "HEAD"
    head = git(path, "rev-parse", "HEAD").stdout.strip()
    main_worktree = git_main_worktree(path) or worktree_path
    return Repo(
        base_path=main_worktree,
        worktree_path=worktree_path,
        common_git_dir=resolve_path(common_git_dir),
        branch=branch,
        head=head,
    )


def git_main_worktree(cwd: Path) -> Path | None:
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
        raise WorktreeGuardError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result

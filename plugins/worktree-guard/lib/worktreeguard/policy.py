"""WorktreeGuard policy for risky Git commands and native file writes."""

from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Union

from .core import BLOCKED_GIT_COMMANDS, Repo, resolve_path
from .git import is_main_worktree, is_ref
from .operations import native_write_targets, operation_is_native_write, operation_is_shell
from .storage import repo_config


CONTROL_TOKENS = {"&&", "||", ";", "|", "&"}
GIT_FLAGS_WITH_VALUES = {"-c", "--config-env", "--exec-path", "--git-dir", "--namespace"}
GIT_FLAGS = {"--bare", "--help", "--no-optional-locks", "--no-pager", "--paginate", "--version"}


@dataclass(frozen=True)
class BlockedGitOperation:
    subcommand: str
    command: str
    cwd: Path
    base_path: Path
    branch_change: bool


@dataclass(frozen=True)
class BlockedFileOperation:
    tool_name: str
    cwd: Path
    base_path: Path
    target: Path | None


BlockedOperation = Union[BlockedGitOperation, BlockedFileOperation]


def blocked_operation(operation: dict[str, object], cwd: Path) -> BlockedOperation | None:
    """Return a blocked ordinary harness operation, if one is in a base checkout."""
    if operation_is_native_write(operation):
        return blocked_file_operation(operation, cwd)
    if operation_is_shell(operation):
        return blocked_git_operation(str(operation.get("command") or ""), cwd)
    return None


def blocked_file_operation(
    operation: dict[str, object], cwd: Path
) -> BlockedFileOperation | None:
    """Block native edit/write targets in a base checkout when writes=block."""
    resolved_cwd = resolve_path(cwd)
    targets = native_write_targets(operation, resolved_cwd)
    for target in targets:
        repo = base_repo_containing(target)
        if repo is not None and _writes_blocked(repo.base_path):
            return BlockedFileOperation(
                str(operation.get("tool_name") or "file write"),
                resolved_cwd,
                repo.base_path,
                target,
            )

    if targets:
        return None
    is_base, repo = is_main_worktree(resolved_cwd)
    if is_base and repo is not None and _writes_blocked(repo.base_path):
        return BlockedFileOperation(
            str(operation.get("tool_name") or "file write"),
            resolved_cwd,
            repo.base_path,
            None,
        )
    return None


def warned_file_operation(
    operation: dict[str, object], cwd: Path
) -> BlockedFileOperation | None:
    """Surface a non-blocking warning for native writes when writes=warn."""
    resolved_cwd = resolve_path(cwd)
    targets = native_write_targets(operation, resolved_cwd)
    for target in targets:
        repo = base_repo_containing(target)
        if repo is not None and _writes_warned(repo.base_path):
            return BlockedFileOperation(
                str(operation.get("tool_name") or "file write"),
                resolved_cwd,
                repo.base_path,
                target,
            )

    if targets:
        return None
    is_base, repo = is_main_worktree(resolved_cwd)
    if is_base and repo is not None and _writes_warned(repo.base_path):
        return BlockedFileOperation(
            str(operation.get("tool_name") or "file write"),
            resolved_cwd,
            repo.base_path,
            None,
        )
    return None


def _writes_blocked(base_path: Path) -> bool:
    config = repo_config(base_path)
    return config.enabled and config.writes == "block"


def _writes_warned(base_path: Path) -> bool:
    config = repo_config(base_path)
    return config.enabled and config.writes == "warn"


def base_repo_containing(target: Path) -> Repo | None:
    context = existing_context_dir(target)
    is_base, repo = is_main_worktree(context)
    if not is_base or repo is None:
        return None
    try:
        target.relative_to(repo.base_path)
    except ValueError:
        return None
    return repo


def existing_context_dir(path: Path) -> Path:
    context = path if path.is_dir() else path.parent
    while not context.exists() and context != context.parent:
        context = context.parent
    return context


def blocked_git_operation(command: str, cwd: Path) -> BlockedGitOperation | None:
    """Return the first explicitly blocked Git invocation in a protected base."""
    segments = shell_segments(command)
    if not segments:
        return None

    active_cwd = resolve_path(cwd)
    for tokens in segments:
        active_cwd = cd_result(tokens, active_cwd)
        invocation = git_invocation(tokens, active_cwd)
        if invocation is None:
            continue
        git_cwd, subcommand, rest = invocation
        if subcommand not in BLOCKED_GIT_COMMANDS:
            continue
        is_base, repo = is_main_worktree(git_cwd)
        if is_base and repo is not None and repo_config(repo.base_path).enabled:
            branch_change = is_branch_change(subcommand, rest, git_cwd)
            return BlockedGitOperation(subcommand, command, git_cwd, repo.base_path, branch_change)
    return None


def is_branch_change(subcommand: str, args: list[str], git_cwd: Path) -> bool:
    """Whether a blocked git checkout/switch actually switches branches.

    git switch always moves HEAD. git checkout only counts when it targets a
    ref (or uses -b/-B), not a path restore.
    """
    if subcommand == "switch":
        return True
    if subcommand != "checkout":
        return False
    positionals: list[str] = []
    for arg in args:
        if arg == "--":
            return False
        if arg in ("-b", "-B"):
            return True
        if not arg.startswith("-"):
            positionals.append(arg)
    if len(positionals) == 1:
        return is_ref(git_cwd, positionals[0])
    return False


def shell_segments(command: str) -> list[list[str]]:
    if not isinstance(command, str) or not command.strip():
        return []
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        return []

    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token in CONTROL_TOKENS:
            if current:
                segments.append(current)
            current = []
        else:
            current.append(token)
    if current:
        segments.append(current)
    return segments


def cd_result(tokens: list[str], cwd: Path) -> Path:
    if not tokens or tokens[0] != "cd" or len(tokens) < 2:
        return cwd
    candidate = Path(tokens[1]).expanduser()
    return resolve_path(candidate if candidate.is_absolute() else cwd / candidate)


def git_invocation(tokens: list[str], cwd: Path) -> tuple[Path, str, list[str]] | None:
    index = command_index(tokens)
    if index is None or Path(tokens[index]).name != "git":
        return None
    return parse_git_args(tokens[index + 1 :], cwd)


def command_index(tokens: list[str]) -> int | None:
    index = 0
    while index < len(tokens) and "=" in tokens[index] and not tokens[index].startswith("="):
        index += 1
    if index < len(tokens) and tokens[index] == "command":
        index += 1
    if index < len(tokens) and tokens[index] == "env":
        index += 1
        while index < len(tokens) and (tokens[index].startswith("-") or "=" in tokens[index]):
            index += 1
    return index if index < len(tokens) else None


def parse_git_args(args: list[str], cwd: Path) -> tuple[Path, str, list[str]] | None:
    remaining = list(args)
    effective_cwd = cwd
    while remaining:
        arg = remaining[0]
        if arg == "-C" and len(remaining) >= 2:
            effective_cwd = relative_path(remaining[1], effective_cwd)
            remaining = remaining[2:]
        elif arg.startswith("-C") and len(arg) > 2:
            effective_cwd = relative_path(arg[2:], effective_cwd)
            remaining = remaining[1:]
        elif arg == "--work-tree" and len(remaining) >= 2:
            effective_cwd = relative_path(remaining[1], effective_cwd)
            remaining = remaining[2:]
        elif arg.startswith("--work-tree="):
            effective_cwd = relative_path(arg.partition("=")[2], effective_cwd)
            remaining = remaining[1:]
        elif arg in GIT_FLAGS_WITH_VALUES and len(remaining) >= 2:
            remaining = remaining[2:]
        elif arg in GIT_FLAGS or any(arg.startswith(f"{flag}=") for flag in GIT_FLAGS_WITH_VALUES):
            remaining = remaining[1:]
        elif arg.startswith("-"):
            return None
        else:
            return effective_cwd, arg, remaining[1:]
    return None


def relative_path(raw: str, cwd: Path) -> Path:
    candidate = Path(raw).expanduser()
    return resolve_path(candidate if candidate.is_absolute() else cwd / candidate)

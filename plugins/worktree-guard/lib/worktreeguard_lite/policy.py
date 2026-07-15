"""WorktreeGuard-lite allow/deny policy and shell parsing."""

from __future__ import annotations

import os
import shlex
from pathlib import Path
from typing import Any

from .core import (
    DANGEROUS_GIT_COMMANDS,
    READ_ONLY_TOOLS,
    SHELL_CONTROL_TOKENS,
    WRITE_TOOLS,
    path_contains,
    resolve_path,
)
from .git import git_effective_cwd, git_main_worktree_matches
from .repositories import protected_repo_for_path


def operation_is_allowed(operation: dict[str, Any], cwd: Path) -> bool:
    tool_name = operation["tool_name"]
    command = operation["command"]
    normalized_tool_name = normalize_tool_name(tool_name)
    if tool_name in READ_ONLY_TOOLS or normalized_tool_name in {"read", "glob", "grep", "ls", "list"}:
        return True
    if operation_is_write_tool(operation):
        return write_operation_targets_allowed(operation, cwd)
    if tool_name.startswith("mcp__"):
        lowered = tool_name.lower()
        return any(token in lowered for token in ("read", "list", "search", "grep", "glob"))
    if tool_name in {"Bash", "Shell"} or command:
        return shell_command_is_read_only_or_control(command, cwd)
    return False


def operation_is_write_tool(operation: dict[str, Any]) -> bool:
    tool_name = operation["tool_name"]
    normalized_tool_name = normalize_tool_name(tool_name)
    return tool_name in WRITE_TOOLS or normalized_tool_name in {
        "applypatch",
        "edit",
        "write",
        "multiedit",
        "notebookedit",
    }


def protected_write_target(operation: dict[str, Any], cwd: Path) -> tuple[Path, dict[str, Any]] | None:
    if not operation_is_write_tool(operation):
        return None
    for target in write_operation_target_paths(operation, cwd):
        context = existing_context_dir(target)
        protected = protected_repo_for_path(context)
        if protected is None:
            continue
        base_path = resolve_path(str(protected["base_path"]))
        if path_contains(base_path, target) and git_main_worktree_matches(base_path, context):
            return base_path, protected
    return None


def write_operation_targets_allowed(operation: dict[str, Any], cwd: Path) -> bool:
    targets = write_operation_target_paths(operation, cwd)
    if not targets:
        return False
    return not any(path_is_protected_main_worktree_target(target) for target in targets)


def write_operation_target_paths(operation: dict[str, Any], cwd: Path) -> list[Path]:
    targets: list[Path] = []
    tool_input = operation.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("file_path", "filepath", "path", "filename", "notebook_path"):
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                targets.append(resolve_operation_path(value, cwd))
    command = operation.get("command")
    if isinstance(command, str):
        targets.extend(apply_patch_target_paths(command, cwd))
    return unique_paths(targets)


def apply_patch_target_paths(command: str, cwd: Path) -> list[Path]:
    prefixes = (
        "*** Add File: ",
        "*** Delete File: ",
        "*** Update File: ",
        "*** Move to: ",
    )
    targets: list[Path] = []
    for line in command.splitlines():
        for prefix in prefixes:
            if line.startswith(prefix):
                raw_path = line.removeprefix(prefix).strip()
                if raw_path:
                    targets.append(resolve_operation_path(raw_path, cwd))
                break
    return targets


def resolve_operation_path(value: str, cwd: Path) -> Path:
    raw_path = Path(os.path.expandvars(value)).expanduser()
    return resolve_path(raw_path if raw_path.is_absolute() else cwd / raw_path)


def unique_paths(paths: list[Path]) -> list[Path]:
    seen: set[Path] = set()
    result: list[Path] = []
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        result.append(path)
    return result


def path_is_protected_main_worktree_target(path: Path) -> bool:
    context = existing_context_dir(path)
    protected = protected_repo_for_path(context)
    if protected is None:
        return False
    base_path = resolve_path(str(protected["base_path"]))
    return path_contains(base_path, path) and git_main_worktree_matches(base_path, context)


def existing_context_dir(path: Path) -> Path:
    candidate = path if path.is_dir() else path.parent
    while not candidate.exists() and candidate != candidate.parent:
        candidate = candidate.parent
    return candidate


def shell_command_is_read_only_or_control(command: str, cwd: Path) -> bool:
    stripped = command.strip()
    if not stripped:
        return True
    try:
        parts = shell_tokens(stripped)
    except ValueError:
        return False
    if not parts:
        return True
    current_cwd = cwd
    for segment, separator in shell_segments(parts):
        if shell_segment_has_dangerous_git(segment, current_cwd):
            return False
        next_cwd = shell_segment_cd_cwd(segment, current_cwd)
        if next_cwd is not None and separator in {None, ";", "&&"}:
            current_cwd = next_cwd
    return True


def shell_tokens(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def shell_segments(parts: list[str]) -> list[tuple[list[str], str | None]]:
    segments: list[tuple[list[str], str | None]] = []
    current: list[str] = []
    for part in parts:
        if part in SHELL_CONTROL_TOKENS:
            if current:
                segments.append((current, part))
                current = []
            continue
        current.append(part)
    if current:
        segments.append((current, None))
    return segments


def shell_segment_has_dangerous_git(parts: list[str], cwd: Path) -> bool:
    while parts and shell_assignment_is_prefix(parts[0]):
        parts = parts[1:]
    if not parts:
        return False
    executable = Path(parts[0]).name
    if executable in {"command", "builtin"}:
        if len(parts) >= 2 and parts[1] == "-v":
            return False
        return shell_segment_has_dangerous_git(parts[1:], cwd)
    if executable in {"env", "sudo", "time"}:
        return shell_segment_has_dangerous_git(shell_wrapper_payload(parts[1:]), cwd)
    if executable in {"bash", "sh", "zsh"}:
        payload = shell_interpreter_payload(parts[1:])
        if payload is None:
            return False
        return not shell_command_is_read_only_or_control(payload, cwd)
    if executable == "git":
        git_cwd, git_args = git_effective_cwd(parts[1:], cwd)
        protected = protected_repo_for_path(git_cwd)
        if protected is None:
            return False
        base_path = resolve_path(str(protected["base_path"]))
        if not path_contains(base_path, git_cwd) or not git_main_worktree_matches(base_path, git_cwd):
            return False
        return not git_command_is_allowed_in_base(git_args, git_cwd)
    return False


def shell_interpreter_payload(args: list[str]) -> str | None:
    remaining = list(args)
    while remaining and shell_assignment_is_prefix(remaining[0]):
        remaining = remaining[1:]
    index = 0
    while index < len(remaining):
        arg = remaining[index]
        if arg == "--":
            index += 1
            continue
        if arg == "-c" or (arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]):
            return remaining[index + 1] if index + 1 < len(remaining) else ""
        if arg.startswith("-"):
            index += 1
            continue
        return None
    return None


def shell_segment_cd_cwd(parts: list[str], cwd: Path) -> Path | None:
    while parts and shell_assignment_is_prefix(parts[0]):
        parts = parts[1:]
    if not parts:
        return None
    executable = Path(parts[0]).name
    offset = 1
    if executable == "builtin" and len(parts) >= 2 and parts[1] == "cd":
        offset = 2
    elif executable != "cd":
        return None
    if len(parts) <= offset:
        return Path.home()
    target = parts[offset]
    if target == "-":
        return None
    raw_path = Path(os.path.expandvars(target)).expanduser()
    candidate = raw_path if raw_path.is_absolute() else cwd / raw_path
    resolved = resolve_path(candidate)
    return resolved if resolved.is_dir() else None


def shell_assignment_is_prefix(part: str) -> bool:
    if "=" not in part:
        return False
    name, _, _ = part.partition("=")
    return bool(name) and (name[0].isalpha() or name[0] == "_") and all(
        character.isalnum() or character == "_" for character in name
    )


def shell_wrapper_payload(args: list[str]) -> list[str]:
    remaining = list(args)
    while remaining and shell_assignment_is_prefix(remaining[0]):
        remaining = remaining[1:]
    while remaining and remaining[0].startswith("-"):
        remaining = remaining[1:]
    while remaining and shell_assignment_is_prefix(remaining[0]):
        remaining = remaining[1:]
    return remaining


def git_command_is_allowed_in_base(args: list[str], cwd: Path) -> bool:
    if not args:
        return True
    return args[0] not in DANGEROUS_GIT_COMMANDS


def normalize_tool_name(tool_name: str) -> str:
    return tool_name.replace("_", "").replace("-", "").lower()

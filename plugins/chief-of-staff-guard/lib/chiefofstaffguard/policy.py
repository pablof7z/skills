"""ChiefOfStaffGuard policy: default-deny allowlist for chief-of-staff sessions.

Chief-of-staff orchestrates and dispatches; it does not implement (standing
doctrine, agent-coordination-standards.md section 5). This module encodes the
exact line drawn there: read-only inspection and coordination tooling is
allowed everywhere; state-mutating actions are blocked everywhere except
chief-of-staff's own tracking-repo home (see `homes.py`).

Like WorktreeGuard, this is not a full sandbox: it recognizes ordinary direct
shell invocations of specific programs (git, gh, rm/mv/cp, curl/wget,
kill/pkill, launchctl/systemctl, sed/find/sort/tee, and plain output
redirection) and a small allowlist of read-only utilities. It does not
evaluate arbitrary interpreters (python3, node, ruby, ...), which is exactly
why those are blocked by default rather than inspected -- a general-purpose
interpreter can perform arbitrary I/O that no static command parse can
verify. When in doubt, the policy fails closed and the doctrine's own
guidance applies: dispatch it.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Union

from .core import resolve_path
from .homes import path_within_allowed_home
from .operations import native_write_targets, operation_is_native_write


CONTROL_TOKENS = {"&&", "||", ";", "|", "&"}
REDIRECT_OPERATORS = {">", ">>"}

GIT_FLAGS_WITH_VALUES = {"-c", "--config-env", "--exec-path", "--git-dir", "--namespace", "-C", "--work-tree"}
GIT_FLAGS = {"--bare", "--help", "--no-optional-locks", "--no-pager", "--paginate", "--version"}
GIT_READ_ONLY_SUBCOMMANDS = frozenset({"status", "log", "diff", "show"})
GIT_BRANCH_SAFE_TOKENS = frozenset({
    "--list", "-l", "-a", "-r", "-v", "-vv", "--show-current", "--no-color", "--color",
})

GH_READ_SUBCOMMAND_PAIRS = frozenset({
    ("pr", "view"), ("pr", "list"), ("pr", "checks"), ("pr", "diff"),
    ("issue", "view"), ("issue", "list"),
    ("repo", "view"),
})
# Filing an issue or opening a PR (or commenting) to *hand off* work is
# legitimate orchestration; resolving/merging/reviewing an existing one is
# not. See README for the full judgment-call writeup.
GH_HANDOFF_SUBCOMMAND_PAIRS = frozenset({
    ("pr", "create"), ("pr", "comment"),
    ("issue", "create"), ("issue", "comment"),
})
GH_API_MUTATING_FLAGS = frozenset({"-f", "--field", "-F", "--field-file", "--input", "--raw-field"})

CURL_MUTATING_FLAGS = frozenset({
    "-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii",
    "-F", "--form", "-T", "--upload-file",
})
CURL_MUTATING_FLAG_PREFIXES = tuple(f"{flag}=" for flag in CURL_MUTATING_FLAGS)

FIND_MUTATING_FLAGS = frozenset({
    "-delete", "-exec", "-execdir", "-fprintf", "-fprint", "-fprint0", "-ok", "-okdir",
})

ALWAYS_BLOCKED_COMMANDS = frozenset({"kill", "pkill", "launchctl", "systemctl"})

SAFE_BARE_COMMANDS = frozenset({
    "ls", "cat", "grep", "egrep", "fgrep", "ps", "lsof", "pwd", "echo", "printf",
    "wc", "head", "tail", "uniq", "diff", "jq", "date", "env", "which", "type",
    "basename", "dirname", "file", "stat", "du", "df", "tree", "true", "false", "cd",
})


@dataclass(frozen=True)
class BlockedShellOperation:
    command: str
    cwd: Path
    program: str
    reason: str


@dataclass(frozen=True)
class BlockedFileOperation:
    tool_name: str
    cwd: Path
    target: Path | None
    reason: str = "chief-of-staff may only write inside its own tracking-repo home"


BlockedOperation = Union[BlockedShellOperation, BlockedFileOperation]


def blocked_operation(operation: dict[str, object], cwd: Path) -> BlockedOperation | None:
    """Return a blocked operation for a chief-of-staff session, if any."""
    if operation_is_native_write(operation):
        return blocked_file_operation(operation, cwd)
    if str(operation.get("tool_name") or "") in {"Bash", "Shell"}:
        return blocked_shell_operation(str(operation.get("command") or ""), cwd)
    return None


def blocked_file_operation(
    operation: dict[str, object], cwd: Path
) -> BlockedFileOperation | None:
    resolved_cwd = resolve_path(cwd)
    tool_name = str(operation.get("tool_name") or "file write")
    targets = native_write_targets(operation, resolved_cwd)
    if targets:
        outside = [target for target in targets if not path_within_allowed_home(target)]
        if outside:
            return BlockedFileOperation(tool_name, resolved_cwd, outside[0])
        return None
    if path_within_allowed_home(resolved_cwd):
        return None
    return BlockedFileOperation(tool_name, resolved_cwd, None)


def blocked_shell_operation(command: str, cwd: Path) -> BlockedShellOperation | None:
    resolved_cwd = resolve_path(cwd)
    segments = shell_segments(command)
    if not segments:
        if command.strip():
            return BlockedShellOperation(command, resolved_cwd, "", "the command could not be parsed")
        return None

    active_cwd = resolved_cwd
    for tokens in segments:
        active_cwd = cd_result(tokens, active_cwd)
        reason = blocked_shell_segment(tokens, active_cwd)
        if reason is not None:
            return BlockedShellOperation(command, resolved_cwd, program_name(tokens) or "", reason)
    return None


def blocked_shell_segment(tokens: list[str], cwd: Path) -> str | None:
    if not tokens:
        return None
    for target in redirection_targets(tokens, cwd):
        if not path_within_allowed_home(target):
            return f"output redirection to {target}, outside chief-of-staff's tracking-repo home"

    index = command_index(tokens)
    if index is None:
        return "the command being run could not be determined"
    program = Path(tokens[index]).name
    args = trim_at_redirect(tokens[index + 1 :])

    handler = PROGRAM_HANDLERS.get(program)
    if handler is not None:
        return handler(args, cwd)
    if program in SAFE_BARE_COMMANDS:
        return None
    if program in ALWAYS_BLOCKED_COMMANDS:
        return f"`{program}` is a process/service-control command"
    return f"`{program}` is not on the read-only/coordination allowlist"


def program_name(tokens: list[str]) -> str | None:
    index = command_index(tokens)
    return Path(tokens[index]).name if index is not None else None


def redirection_targets(tokens: list[str], cwd: Path) -> list[Path]:
    targets: list[Path] = []
    for position, token in enumerate(tokens):
        if token in REDIRECT_OPERATORS and position + 1 < len(tokens):
            targets.append(relative_path(tokens[position + 1], cwd))
    return targets


def trim_at_redirect(tokens: list[str]) -> list[str]:
    for position, token in enumerate(tokens):
        if token in REDIRECT_OPERATORS:
            return tokens[:position]
    return tokens


def classify_git(args: list[str], cwd: Path) -> str | None:
    parsed = git_subcommand(args)
    if parsed is None:
        return "the git subcommand could not be determined"
    subcommand, rest = parsed
    if subcommand in GIT_READ_ONLY_SUBCOMMANDS:
        return None
    if subcommand == "branch":
        if all(token in GIT_BRANCH_SAFE_TOKENS for token in rest):
            return None
        return "`git branch` with a name or a mutating flag (-d/-D/-m/-M/-c/-C) is a write form"
    return (
        f"`git {subcommand}` is not a read-only form "
        "(only status/log/diff/show and `branch --list` are allowed)"
    )


def git_subcommand(args: list[str]) -> tuple[str, list[str]] | None:
    remaining = list(args)
    while remaining:
        arg = remaining[0]
        if arg in GIT_FLAGS_WITH_VALUES and len(remaining) >= 2:
            remaining = remaining[2:]
        elif arg in GIT_FLAGS or any(arg.startswith(f"{flag}=") for flag in GIT_FLAGS_WITH_VALUES):
            remaining = remaining[1:]
        elif arg.startswith("-"):
            return None
        else:
            return arg, remaining[1:]
    return None


def classify_gh(args: list[str], cwd: Path) -> str | None:
    if not args:
        return "`gh` with no subcommand is not on the allowlist"
    noun = args[0]
    if noun == "api":
        return classify_gh_api(args[1:])
    if len(args) < 2:
        return f"`gh {noun}` with no verb is not on the allowlist"
    pair = (noun, args[1])
    if pair in GH_READ_SUBCOMMAND_PAIRS or pair in GH_HANDOFF_SUBCOMMAND_PAIRS:
        return None
    return (
        f"`gh {noun} {args[1]}` is not on the allowlist "
        "(view/list/checks/diff reads and create/comment handoffs only; "
        "merge/close/edit/review are blocked)"
    )


def classify_gh_api(args: list[str]) -> str | None:
    for position, token in enumerate(args):
        if token in ("-X", "--method"):
            method = args[position + 1].upper() if position + 1 < len(args) else ""
            if method and method not in ("GET", "HEAD"):
                return f"`gh api --method {method}` is not a GET-style read"
        elif token in GH_API_MUTATING_FLAGS or any(
            token.startswith(f"{flag}=") for flag in GH_API_MUTATING_FLAGS
        ):
            return f"`gh api {token}` looks like it submits data, not a GET-style read"
    return None


def classify_curl(args: list[str], cwd: Path) -> str | None:
    for position, token in enumerate(args):
        if token in ("-X", "--request"):
            method = args[position + 1].upper() if position + 1 < len(args) else ""
            if method and method not in ("GET", "HEAD"):
                return f"`curl -X {method}` is not a plain GET/read"
        elif token in CURL_MUTATING_FLAGS or token.startswith(CURL_MUTATING_FLAG_PREFIXES):
            return f"`curl {token}` sends data, not a plain GET/read"
    return None


def classify_wget(args: list[str], cwd: Path) -> str | None:
    for token in args:
        if token.startswith("--post-data") or token.startswith("--post-file") or token.startswith("--method"):
            return f"`wget {token}` is not a plain GET/read"
    return None


def classify_fs_write(name: str, args: list[str], cwd: Path) -> str | None:
    paths = [relative_path(token, cwd) for token in args if not token.startswith("-")]
    if not paths:
        return f"`{name}` with no resolvable path defaults to blocked"
    outside = [path for path in paths if not path_within_allowed_home(path)]
    if outside:
        return f"`{name}` targets {outside[0]}, outside chief-of-staff's tracking-repo home"
    return None


def classify_tee(args: list[str], cwd: Path) -> str | None:
    paths = [relative_path(token, cwd) for token in args if not token.startswith("-")]
    outside = [path for path in paths if not path_within_allowed_home(path)]
    if outside:
        return f"`tee` writes to {outside[0]}, outside chief-of-staff's tracking-repo home"
    return None


def classify_sed(args: list[str], cwd: Path) -> str | None:
    for token in args:
        if token == "-i" or token.startswith("-i") or token == "--in-place" or token.startswith("--in-place="):
            return "`sed -i` edits files in place"
    return None


def classify_find(args: list[str], cwd: Path) -> str | None:
    for token in args:
        if token in FIND_MUTATING_FLAGS:
            return f"`find ... {token}` mutates state or runs arbitrary commands"
    return None


def classify_sort(args: list[str], cwd: Path) -> str | None:
    for token in args:
        if token == "-o" or token == "--output" or token.startswith("--output="):
            return "`sort -o` writes to a file"
    return None


PROGRAM_HANDLERS: dict[str, Callable[[list[str], Path], str | None]] = {
    "git": classify_git,
    "gh": classify_gh,
    "mosaico": lambda args, cwd: None,
    "rm": lambda args, cwd: classify_fs_write("rm", args, cwd),
    "mv": lambda args, cwd: classify_fs_write("mv", args, cwd),
    "cp": lambda args, cwd: classify_fs_write("cp", args, cwd),
    "curl": classify_curl,
    "wget": classify_wget,
    "tee": classify_tee,
    "sed": classify_sed,
    "find": classify_find,
    "sort": classify_sort,
}


def shell_segments(command: str) -> list[list[str]]:
    if not isinstance(command, str) or not command.strip():
        return []
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|><")
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


def relative_path(raw: str, cwd: Path) -> Path:
    candidate = Path(raw).expanduser()
    return resolve_path(candidate if candidate.is_absolute() else cwd / candidate)

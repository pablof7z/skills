"""Small local WorktreeGuard implementation bundled with the Codex plugin."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


READ_ONLY_TOOLS = {"Read", "Glob", "Grep", "LS"}
WRITE_TOOLS = {"apply_patch", "Edit", "Write", "MultiEdit", "NotebookEdit"}
READ_ONLY_COMMANDS = {"cat", "grep", "head", "ls", "pwd", "rg", "tail"}
WTG_CONTROL_COMMANDS = {
    "create-worktree",
    "current",
    "doctor",
    "hook",
    "protect",
    "request-base-access",
    "status",
}
SHELL_META = ("\n", "&&", "||", ";", "|", ">", "<", "`", "$(")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except WorktreeGuardError as error:
        print(str(error), file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wtg")
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="Initialize local WorktreeGuard state")
    init_parser.add_argument("--repo", default=".")
    init_parser.set_defaults(func=cmd_init)

    protect_parser = subparsers.add_parser("protect", help="Protect a clean base checkout")
    protect_parser.add_argument("--repo", default=".")
    protect_parser.set_defaults(func=cmd_protect)

    status_parser = subparsers.add_parser("status", help="Show protection status")
    status_parser.add_argument("--repo", default=".")
    status_parser.set_defaults(func=cmd_status)

    current_parser = subparsers.add_parser("current", help="Show current repo context")
    current_parser.add_argument("--repo", default=".")
    current_parser.set_defaults(func=cmd_current)

    create_parser = subparsers.add_parser("create-worktree", help="Create an agent worktree")
    create_parser.add_argument("--repo", default=".")
    create_parser.add_argument("--name", required=True)
    create_parser.add_argument("--base-ref")
    create_parser.add_argument("--branch")
    create_parser.add_argument("--print-env", action="store_true")
    create_parser.set_defaults(func=cmd_create_worktree)

    request_parser = subparsers.add_parser(
        "request-base-access",
        help="Explain why protected base access is needed",
    )
    request_parser.add_argument("--repo", default=".")
    request_parser.add_argument("--reason", required=True)
    request_parser.add_argument("--scope", default="session")
    request_parser.add_argument("--wait", action="store_true")
    request_parser.add_argument("--timeout", type=int, default=0)
    request_parser.set_defaults(func=cmd_request_base_access)

    doctor_parser = subparsers.add_parser("doctor", help="Check local WorktreeGuard-lite setup")
    doctor_parser.set_defaults(func=cmd_doctor)

    hook_parser = subparsers.add_parser("hook", help="Run a harness hook")
    hook_subparsers = hook_parser.add_subparsers(dest="harness", required=True)
    codex_parser = hook_subparsers.add_parser("codex")
    codex_parser.add_argument("event", nargs="?", default="hook")
    codex_parser.set_defaults(func=cmd_hook_codex)

    return parser


def cmd_init(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    state = load_state()
    state.setdefault("repos", {})
    save_state(state)
    print(f"Initialized WorktreeGuard state for {repo.base_path}")
    return 0


def cmd_protect(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    status = git(repo.base_path, "status", "--porcelain=v1", "-z").stdout
    if status:
        raise WorktreeGuardError(
            "Cannot protect this repo yet.\n\n"
            "The base checkout must be clean first:\n"
            f"  branch: {repo.branch}\n\n"
            "Commit, stash, or discard local changes, then run protect again."
        )

    state = load_state()
    repos = state.setdefault("repos", {})
    repos[str(repo.base_path)] = {
        "base_path": str(repo.base_path),
        "common_git_dir": str(repo.common_git_dir),
        "branch": repo.branch,
        "head": repo.head,
        "worktree_root": str(default_worktree_root(repo.base_path)),
        "protected_at": int(time.time()),
    }
    save_state(state)
    print(f"Protected base checkout: {repo.base_path}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    protected = protected_repo_for_path(repo.base_path)
    if protected is None:
        print(f"Not protected: {repo.base_path}")
        return 1
    print(f"Protected: {protected['base_path']}")
    print(f"Branch: {protected.get('branch', repo.branch)}")
    print(f"HEAD: {protected.get('head', repo.head)}")
    print(f"Worktree root: {protected.get('worktree_root')}")
    return 0


def cmd_current(args: argparse.Namespace) -> int:
    path = resolve_path(args.repo)
    repo = discover_repo(path)
    protected = protected_repo_for_path(path)
    payload = {
        "cwd": str(path),
        "repo": str(repo.base_path),
        "protected": protected is not None and path_contains(Path(protected["base_path"]), path),
        "worktree": not path_contains(repo.base_path, path),
    }
    print(json.dumps(payload, indent=2))
    return 0


def cmd_create_worktree(args: argparse.Namespace) -> int:
    cwd = resolve_path(args.repo)
    protected = protected_repo_for_path(cwd)
    if protected is None:
        repo = discover_repo(cwd)
        raise WorktreeGuardError(
            "No protected base checkout found for this repo.\n\n"
            f"Protect the base checkout first:\n  {command_name()} protect --repo {shlex.quote(str(repo.base_path))}"
        )

    base_path = Path(protected["base_path"])
    repo = discover_repo(base_path)
    task = slugify(args.name)
    suffix = short_suffix()
    branch = args.branch or f"agent/{task}-{suffix}"
    path = unique_worktree_path(Path(protected["worktree_root"]), task, suffix)
    base_ref = args.base_ref or default_base_ref(repo)

    git(base_path, "worktree", "add", "-b", branch, str(path), base_ref)

    state = load_state()
    worktrees = state.setdefault("worktrees", {})
    worktrees[str(path)] = {
        "base_path": str(base_path),
        "branch": branch,
        "base_ref": base_ref,
        "created_at": int(time.time()),
    }
    save_state(state)

    if args.print_env:
        print(f"export WTG_BASE_PATH={shlex.quote(str(base_path))}")
        print(f"export WTG_WORKTREE_PATH={shlex.quote(str(path))}")
    print(path)
    return 0


def cmd_request_base_access(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    print(
        "No human approval UI is bundled with WorktreeGuard-lite.\n\n"
        "Continue in a worktree instead:\n"
        f"  {command_name()} create-worktree --repo {shlex.quote(str(repo.base_path))} --name <short-task-name>\n\n"
        f"Recorded reason: {args.reason}",
        file=sys.stderr,
    )
    return 1


def cmd_doctor(args: argparse.Namespace) -> int:
    git_path = shutil.which("git")
    print(f"git: {git_path or 'missing'}")
    print(f"state: {state_path()}")
    state = load_state()
    repos = state.get("repos", {})
    print(f"protected repos: {len(repos)}")
    for repo in repos.values():
        print(f"- {repo.get('base_path')}")
    return 0 if git_path else 1


def cmd_hook_codex(args: argparse.Namespace) -> int:
    payload = load_hook_payload(sys.stdin.buffer.read())
    return run_codex_hook(args.event, payload)


def run_codex_hook(event: str, payload: dict[str, Any]) -> int:
    if event == "session-start":
        return emit_session_context(payload)

    if event not in {"pre-tool-use", "permission-request"}:
        return 0

    cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    protected = protected_repo_for_path(cwd)
    if protected is None:
        return 0

    base_path = Path(protected["base_path"])
    if not path_contains(base_path, cwd):
        return 0

    operation = extract_operation(payload)
    if operation_is_allowed(operation):
        return 0

    message = denial_message(base_path)
    if event == "permission-request":
        emit(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "deny", "message": message},
                }
            }
        )
    else:
        emit(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": message,
                }
            }
        )
    return 0


def emit_session_context(payload: dict[str, Any]) -> int:
    cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    protected = protected_repo_for_path(cwd)
    command = command_name()
    if protected is None:
        context = (
            "WorktreeGuard Codex is installed. This repo is not protected yet.\n\n"
            "To test it, protect a clean base checkout:\n"
            f"  {command} protect --repo {shlex.quote(str(cwd))}"
        )
    else:
        base_path = Path(protected["base_path"])
        context = (
            "WorktreeGuard Codex is active for this protected base checkout:\n"
            f"{base_path}\n\n"
            "Use a worktree for mutating work:\n"
            f"  {command} create-worktree --repo {shlex.quote(str(base_path))} --name <short-task-name>"
        )
    emit({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}})
    return 0


def protected_repo_for_path(path: Path) -> dict[str, Any] | None:
    path = resolve_path(path)
    env_base = os.environ.get("WTG_PROTECTED_BASE") or os.environ.get("WTG_BASE_PATH")
    if env_base:
        base = resolve_path(env_base)
        if path_contains(base, path):
            return {
                "base_path": str(base),
                "worktree_root": str(default_worktree_root(base)),
            }

    env_worktree = os.environ.get("WTG_WORKTREE_PATH")
    if env_worktree and path_contains(resolve_path(env_worktree), path):
        return None

    state = load_state()
    for repo in state.get("repos", {}).values():
        base_path = resolve_path(repo.get("base_path", ""))
        if path_contains(base_path, path):
            return repo

    try:
        repo = discover_repo(path)
    except WorktreeGuardError:
        return None
    marker = repo.base_path / ".wtg.toml"
    if marker.is_file() and path_contains(repo.base_path, path):
        return {
            "base_path": str(repo.base_path),
            "common_git_dir": str(repo.common_git_dir),
            "branch": repo.branch,
            "head": repo.head,
            "worktree_root": str(default_worktree_root(repo.base_path)),
        }
    return None


def extract_operation(payload: dict[str, Any]) -> dict[str, Any]:
    event = payload.get("event") if isinstance(payload.get("event"), dict) else {}
    tool = payload.get("tool") if isinstance(payload.get("tool"), dict) else {}
    tool_name = (
        payload.get("tool_name")
        or event.get("tool_name")
        or tool.get("name")
        or payload.get("tool")
        or ""
    )
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = tool.get("input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    command = tool_input.get("command") or tool_input.get("cmd") or payload.get("command") or ""
    return {"tool_name": str(tool_name), "command": str(command), "tool_input": tool_input}


def operation_is_allowed(operation: dict[str, Any]) -> bool:
    tool_name = operation["tool_name"]
    command = operation["command"]
    if tool_name in READ_ONLY_TOOLS:
        return True
    if tool_name in WRITE_TOOLS:
        return False
    if tool_name.startswith("mcp__"):
        lowered = tool_name.lower()
        return any(token in lowered for token in ("read", "list", "search", "grep", "glob"))
    if tool_name in {"Bash", "Shell"} or command:
        return shell_command_is_read_only_or_control(command)
    return False


def shell_command_is_read_only_or_control(command: str) -> bool:
    stripped = command.strip()
    if not stripped:
        return True
    if any(token in stripped for token in SHELL_META):
        return False
    try:
        parts = shlex.split(stripped)
    except ValueError:
        return False
    if not parts:
        return True
    executable = Path(parts[0]).name
    if executable == "wtg" or parts[0] == command_name():
        return len(parts) >= 2 and parts[1] in WTG_CONTROL_COMMANDS
    if executable == "git":
        return git_command_is_read_only(parts[1:])
    if executable == "find":
        return find_command_is_read_only(parts[1:])
    return executable in READ_ONLY_COMMANDS


def git_command_is_read_only(args: list[str]) -> bool:
    if not args:
        return False
    subcommand = args[0]
    rest = args[1:]
    if subcommand in {"status", "log", "show", "rev-parse", "ls-files"}:
        return True
    if subcommand == "diff":
        return not any(arg == "--output" or arg.startswith("--output=") for arg in rest)
    if subcommand == "branch":
        return rest == ["--show-current"]
    if subcommand == "remote":
        return rest == ["-v"]
    if subcommand == "worktree":
        return bool(rest) and rest[0] == "list"
    return False


def find_command_is_read_only(args: list[str]) -> bool:
    mutating_flags = {"-delete", "-exec", "-execdir", "-ok", "-okdir"}
    return not any(arg in mutating_flags for arg in args)


def denial_message(base_path: Path) -> str:
    command = command_name()
    return (
        "Denied by WorktreeGuard.\n\n"
        "You are in the protected base checkout:\n"
        f"{base_path}\n\n"
        "This session may read this checkout, but may not edit files, switch "
        "branches, or mutate Git state here.\n\n"
        "Create a worktree and continue there:\n\n"
        f"  {command} create-worktree --repo {shlex.quote(str(base_path))} --name <short-task-name>\n"
        "  cd <printed-worktree-path>\n\n"
        "If base access is truly required, request a human grant with a "
        "specific reason:\n\n"
        f"  {command} request-base-access --repo {shlex.quote(str(base_path))} \\\n"
        "    --reason \"<why this cannot be done in a worktree>\" \\\n"
        "    --scope session"
    )


def load_hook_payload(stdin: bytes) -> dict[str, Any]:
    if not stdin.strip():
        return {}
    try:
        payload = json.loads(stdin.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def load_state() -> dict[str, Any]:
    path = state_path()
    if not path.is_file():
        return {"version": 1, "repos": {}, "worktrees": {}}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"version": 1, "repos": {}, "worktrees": {}}
    if not isinstance(payload, dict):
        return {"version": 1, "repos": {}, "worktrees": {}}
    payload.setdefault("version", 1)
    payload.setdefault("repos", {})
    payload.setdefault("worktrees", {})
    return payload


def save_state(state: dict[str, Any]) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def state_path() -> Path:
    override = os.environ.get("WTG_STATE_FILE")
    if override:
        return resolve_path(override)
    return Path.home() / ".local" / "state" / "worktreeguard" / "lite-state.json"


def discover_repo(path: Path) -> "Repo":
    path = resolve_path(path)
    top = git(path, "rev-parse", "--show-toplevel").stdout.strip()
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
    main_worktree = git_main_worktree(path) or resolve_path(top)
    return Repo(
        base_path=main_worktree,
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


def default_base_ref(repo: "Repo") -> str:
    result = subprocess.run(
        ["git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/main"],
        cwd=str(repo.base_path),
        check=False,
    )
    return "origin/main" if result.returncode == 0 else repo.head


def default_worktree_root(base_path: Path) -> Path:
    return base_path.parent / ".worktrees" / base_path.name


def unique_worktree_path(root: Path, task: str, suffix: str) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    candidate = root / f"{task}-{suffix}"
    while candidate.exists():
        suffix = short_suffix()
        candidate = root / f"{task}-{suffix}"
    return candidate


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", value.strip().lower()).strip("-")
    return slug[:40] or "task"


def short_suffix() -> str:
    return hashlib.sha1(str(random.random()).encode("utf-8")).hexdigest()[:4]


def resolve_path(raw_path: str | Path) -> Path:
    return Path(raw_path).expanduser().resolve(strict=False)


def path_contains(parent: Path, child: Path) -> bool:
    try:
        child.relative_to(parent)
    except ValueError:
        return False
    return True


def command_name() -> str:
    raw = os.environ.get("WTG_COMMAND") or sys.argv[0] or "wtg"
    if raw == "wtg":
        return "wtg"
    return shlex.quote(str(resolve_path(raw)))


def emit(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


class WorktreeGuardError(RuntimeError):
    pass


class Repo:
    def __init__(self, *, base_path: Path, common_git_dir: Path, branch: str, head: str) -> None:
        self.base_path = base_path
        self.common_git_dir = common_git_dir
        self.branch = branch
        self.head = head

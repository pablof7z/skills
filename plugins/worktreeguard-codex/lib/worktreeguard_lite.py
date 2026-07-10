"""Small local WorktreeGuard implementation bundled with the Codex plugin."""

from __future__ import annotations

import argparse
import json
import os
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
    "current",
    "doctor",
    "hook",
    "protect",
    "request-base-access",
    "status",
}
DEFAULT_GRANT_TTL_SECONDS = 30 * 60
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

    request_parser = subparsers.add_parser(
        "request-base-access",
        help="Ask the local human for temporary protected-base access",
    )
    request_parser.add_argument("--repo", default=".")
    request_parser.add_argument("--reason", required=True)
    request_parser.add_argument("--scope", default="session", choices=["once", "operation", "session"])
    request_parser.add_argument("--ttl-seconds", type=int, default=DEFAULT_GRANT_TTL_SECONDS)
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


def cmd_request_base_access(args: argparse.Namespace) -> int:
    repo = discover_repo(Path(args.repo))
    protected = protected_repo_for_path(repo.base_path)
    if protected is None:
        raise WorktreeGuardError(
            "Base access grants only apply to Git main worktrees."
        )

    base_path = Path(protected["base_path"])
    decision = request_human_approval(
        repo=repo,
        reason=args.reason,
        requested_scope=args.scope,
        timeout=args.timeout,
    )
    if decision is None:
        print(
            "Denied. Continue from a Git worktree instead.",
            file=sys.stderr,
        )
        return 1

    grant = create_grant(
        base_path=base_path,
        scope=decision,
        reason=args.reason,
        ttl_seconds=args.ttl_seconds,
    )
    print(f"Approved until {time.strftime('%Y-%m-%dT%H:%M:%S%z', time.localtime(grant['expires_at']))}.")
    print("Retry the previous operation.")
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    git_path = shutil.which("git")
    print(f"git: {git_path or 'missing'}")
    print(f"state: {state_path()}")
    state = load_state()
    repos = state.get("repos", {})
    grants = active_grants(state)
    print(f"protected repos: {len(repos)}")
    for repo in repos.values():
        print(f"- {repo.get('base_path')}")
    print(f"active grants: {len(grants)}")
    return 0 if git_path else 1


def cmd_hook_codex(args: argparse.Namespace) -> int:
    payload = load_hook_payload(sys.stdin.buffer.read())
    return run_codex_hook(args.event, payload)


def run_codex_hook(event: str, payload: dict[str, Any]) -> int:
    if event == "session-start":
        return emit_session_context(payload)

    if event not in {"pre-tool-use", "permission-request"}:
        return 0

    session_cwd = resolve_path(str(payload.get("cwd") or os.getcwd()))
    operation = extract_operation(payload)
    cwd = effective_operation_cwd(operation, session_cwd)
    protected = protected_repo_for_path(cwd)
    if protected is None:
        return 0

    base_path = Path(protected["base_path"])
    if not path_contains(base_path, cwd):
        return 0

    if operation_is_allowed(operation, cwd):
        return 0

    if has_valid_grant(base_path):
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
    if protected is not None:
        base_path = Path(protected["base_path"])
        context = (
            "WorktreeGuard Codex is active for this protected base checkout:\n"
            f"{base_path}\n\n"
            "Do mutating work from a Git worktree, not this protected base checkout."
        )
    else:
        try:
            repo = discover_repo(cwd)
        except WorktreeGuardError:
            context = "WorktreeGuard Codex is installed. This directory is not in a Git repo."
        else:
            context = (
                "WorktreeGuard Codex is active. This directory is a Git worktree for "
                "the protected base checkout:\n"
                f"{repo.base_path}\n\n"
                "Mutating work is allowed in this worktree."
            )
    emit({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}})
    return 0


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
    if marker.is_file() and path_contains(repo.base_path, path):
        return {
            "base_path": str(repo.base_path),
            "common_git_dir": str(repo.common_git_dir),
            "branch": repo.branch,
            "head": repo.head,
        }
    if path_contains(repo.base_path, path):
        return {
            "base_path": str(repo.base_path),
            "common_git_dir": str(repo.common_git_dir),
            "branch": repo.branch,
            "head": repo.head,
            "default_protected": True,
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


def effective_operation_cwd(operation: dict[str, Any], fallback: Path) -> Path:
    cwd = fallback
    tool_input = operation.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("workdir", "cwd", "working_directory", "directory"):
            raw_value = tool_input.get(key)
            if not isinstance(raw_value, str) or not raw_value.strip():
                continue
            candidate = Path(raw_value).expanduser()
            if not candidate.is_absolute():
                candidate = fallback / candidate
            cwd = resolve_path(candidate)
            break

    command_cwd = git_command_cwd(operation.get("command", ""), cwd)
    return command_cwd or cwd


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


def operation_is_allowed(operation: dict[str, Any], cwd: Path) -> bool:
    tool_name = operation["tool_name"]
    command = operation["command"]
    normalized_tool_name = normalize_tool_name(tool_name)
    if tool_name in READ_ONLY_TOOLS or normalized_tool_name in {"read", "glob", "grep", "ls", "list"}:
        return True
    if tool_name in WRITE_TOOLS or normalized_tool_name in {
        "applypatch",
        "edit",
        "write",
        "multiedit",
        "notebookedit",
    }:
        return False
    if tool_name.startswith("mcp__"):
        lowered = tool_name.lower()
        return any(token in lowered for token in ("read", "list", "search", "grep", "glob"))
    if tool_name in {"Bash", "Shell"} or command:
        return shell_command_is_read_only_or_control(command, cwd)
    return False


def shell_command_is_read_only_or_control(command: str, cwd: Path) -> bool:
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
        git_cwd, git_args = git_effective_cwd(parts[1:], cwd)
        return git_command_is_allowed_in_base(git_args, git_cwd)
    if executable == "find":
        return find_command_is_read_only(parts[1:])
    return executable in READ_ONLY_COMMANDS


def git_command_is_allowed_in_base(args: list[str], cwd: Path) -> bool:
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
        return git_worktree_command_is_allowed(rest, cwd)
    return False


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
        if arg in {"-c", "--config-env", "--exec-path", "--git-dir", "--work-tree", "--namespace"}:
            if len(remaining) < 2:
                return effective_cwd, remaining
            remaining = remaining[2:]
            continue
        if arg in {"--no-pager", "--paginate", "--bare", "--version", "--help"}:
            remaining = remaining[1:]
            continue
        break
    return effective_cwd, remaining


def git_worktree_command_is_allowed(args: list[str], cwd: Path) -> bool:
    if not args:
        return False
    action = args[0]
    if action == "list":
        return True
    if action != "add":
        return False
    target = git_worktree_add_path(args[1:])
    if target is None:
        return False
    protected = protected_repo_for_path(cwd)
    if protected is None:
        return True
    base_path = Path(protected["base_path"])
    target_path = target if target.is_absolute() else cwd / target
    return not path_contains(base_path, resolve_path(target_path))


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


def normalize_tool_name(tool_name: str) -> str:
    return tool_name.replace("_", "").replace("-", "").lower()


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
    return repo


def git_main_worktree_matches(base_path: Path, path: Path) -> bool:
    try:
        repo = discover_repo(path)
    except WorktreeGuardError:
        return False
    return repo.base_path == base_path


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
        "Continue from a Git worktree instead. Use the repository's normal "
        "worktree workflow; WorktreeGuard will allow mutations outside this "
        "protected base checkout.\n\n"
        "If base access is truly required, ask for a human approval:\n\n"
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
        return {"version": 1, "repos": {}, "worktrees": {}, "grants": []}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"version": 1, "repos": {}, "worktrees": {}, "grants": []}
    if not isinstance(payload, dict):
        return {"version": 1, "repos": {}, "worktrees": {}, "grants": []}
    payload.setdefault("version", 1)
    payload.setdefault("repos", {})
    payload.setdefault("worktrees", {})
    payload.setdefault("grants", [])
    return payload


def save_state(state: dict[str, Any]) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def request_human_approval(
    *,
    repo: "Repo",
    reason: str,
    requested_scope: str,
    timeout: int,
) -> str | None:
    override = os.environ.get("WTG_APPROVAL_RESPONSE")
    if override:
        normalized = override.strip().lower()
        if normalized in {"allow", "approve", "session"}:
            return "session" if requested_scope == "session" else "once"
        if normalized in {"once", "operation"}:
            return "once"
        return None

    if sys.platform != "darwin":
        raise WorktreeGuardError(
            "No approval UI is available on this platform in WorktreeGuard-lite."
        )

    prompt = (
        "Codex is requesting protected base checkout access.\n\n"
        f"Repo: {repo.base_path}\n"
        f"Branch: {repo.branch}\n"
        f"Scope requested: {requested_scope}\n\n"
        f"Reason:\n{reason}"
    )
    script = [
        "display dialog "
        + apple_string(prompt)
        + ' buttons {"Deny", "Allow once", "Allow session"} '
        + 'default button "Deny" cancel button "Deny" with icon caution',
        "button returned of result",
    ]
    args = ["osascript"]
    for expression in script:
        args.extend(["-e", expression])

    try:
        result = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout if timeout > 0 else None,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None
    if result.returncode != 0:
        return None
    button = result.stdout.strip()
    if button == "Allow session":
        return "session"
    if button == "Allow once":
        return "once"
    return None


def create_grant(
    *,
    base_path: Path,
    scope: str,
    reason: str,
    ttl_seconds: int,
) -> dict[str, Any]:
    now = int(time.time())
    grant = {
        "id": f"grant-{now}-{os.getpid()}",
        "base_path": str(base_path),
        "scope": scope,
        "reason": reason,
        "created_at": now,
        "expires_at": now + max(1, ttl_seconds),
    }
    state = load_state()
    grants = state.setdefault("grants", [])
    if not isinstance(grants, list):
        grants = []
        state["grants"] = grants
    grants.append(grant)
    save_state(state)
    return grant


def has_valid_grant(base_path: Path) -> bool:
    state = load_state()
    now = int(time.time())
    changed = False
    for grant in state.get("grants", []):
        if not isinstance(grant, dict):
            continue
        if grant.get("base_path") != str(base_path):
            continue
        if int(grant.get("expires_at", 0)) <= now:
            continue
        if grant.get("revoked_at") is not None:
            continue
        scope = grant.get("scope")
        if scope == "session":
            return True
        if scope in {"once", "operation"} and grant.get("used_at") is None:
            grant["used_at"] = now
            changed = True
            save_state(state)
            return True
    if changed:
        save_state(state)
    return False


def active_grants(state: dict[str, Any]) -> list[dict[str, Any]]:
    now = int(time.time())
    result = []
    for grant in state.get("grants", []):
        if not isinstance(grant, dict):
            continue
        if int(grant.get("expires_at", 0)) <= now:
            continue
        if grant.get("revoked_at") is not None:
            continue
        if grant.get("scope") in {"once", "operation"} and grant.get("used_at") is not None:
            continue
        result.append(grant)
    return result


def apple_string(value: str) -> str:
    lines = value.splitlines() or [""]
    quoted_lines = [
        '"' + line.replace("\\", "\\\\").replace('"', '\\"') + '"'
        for line in lines
    ]
    return " & return & ".join(quoted_lines)


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

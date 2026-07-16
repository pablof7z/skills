"""Durable daemon lifecycle helpers for remote approval roles."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .storage import state_path


def daemon_pid_path(role: str) -> Path:
    return state_path().parent / f"{role}.pid"


def running_pid(path: Path) -> int | None:
    try:
        pid = int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    if pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        return pid
    return pid


def daemon_status(role: str) -> dict[str, Any]:
    path = daemon_pid_path(role)
    pid = running_pid(path)
    if pid is None and path.exists():
        try:
            path.unlink()
        except OSError:
            pass
    return {"role": role, "running": pid is not None, "pid": pid, "pid_file": str(path)}


def start_daemon(role: str, *, timeout: int) -> dict[str, Any]:
    status = daemon_status(role)
    if status["running"]:
        return {**status, "started": False}
    path = daemon_pid_path(role)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    command = [
        sys.executable,
        str(Path(__file__).resolve().parents[2] / "bin" / "wtg"),
        "daemon",
        role,
        "foreground",
        "--timeout",
        str(timeout),
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=os.environ.copy(),
        start_new_session=True,
    )
    path.write_text(f"{process.pid}\n", encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass
    return {**daemon_status(role), "started": True}


def stop_daemon(role: str, *, wait_seconds: float = 5.0) -> dict[str, Any]:
    path = daemon_pid_path(role)
    pid = running_pid(path)
    if pid is None:
        cleanup_pid(path)
        return {"role": role, "running": False, "stopped": False, "pid": None}
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + max(0.1, wait_seconds)
    while time.monotonic() < deadline:
        if running_pid(path) is None:
            cleanup_pid(path)
            return {"role": role, "running": False, "stopped": True, "pid": pid}
        time.sleep(0.05)
    return {"role": role, "running": True, "stopped": False, "pid": pid}


def cleanup_pid(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass

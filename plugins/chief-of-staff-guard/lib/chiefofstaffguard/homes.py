"""Chief-of-staff's own allowed self-management locations.

Per the standing doctrine (agent-coordination-standards.md section 5),
editing files strictly within chief-of-staff's own tracking-repo checkout or
its own agent home is self-management, not implementation work, and stays
allowed. Both locations are overridable by environment variable so this
policy is not hard-coded to one machine's paths.
"""

from __future__ import annotations

import os
from pathlib import Path

from .core import CHIEF_OF_STAFF_SLUG, resolve_path

TRACKING_REPO_HOME_ENV = "COSG_TRACKING_REPO_HOME"
AGENT_HOME_ENV = "COSG_AGENT_HOME"


def tracking_repo_home() -> Path:
    override = os.environ.get(TRACKING_REPO_HOME_ENV)
    if override:
        return resolve_path(override)
    return resolve_path(Path.home() / "src" / "everything")


def agent_home() -> Path:
    override = os.environ.get(AGENT_HOME_ENV)
    if override:
        return resolve_path(override)
    return resolve_path(Path.home() / ".agents" / "homes" / CHIEF_OF_STAFF_SLUG)


def allowed_home_paths() -> tuple[Path, ...]:
    return (tracking_repo_home(), agent_home())


def path_within_allowed_home(target: Path) -> bool:
    for home in allowed_home_paths():
        try:
            target.relative_to(home)
            return True
        except ValueError:
            continue
    return False

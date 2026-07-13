#!/usr/bin/env python3
"""Create or append a canonical skill meta-feedback issue."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REQUIRED_FIELDS = (
    "skill",
    "title",
    "problem",
    "agent",
    "incident",
    "context",
    "expected",
    "observed",
    "impact",
    "workaround",
)
VAGUE_TITLE_WORDS = {
    "bad",
    "confusing",
    "feedback",
    "improve",
    "issue",
    "misc",
    "other",
    "problem",
}
SLUG_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
TITLE_PATTERN = re.compile(r"[A-Za-z0-9]+(?:[ -][A-Za-z0-9]+)*\Z")
IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9@][A-Za-z0-9@._:/-]{0,127}\Z")
INCIDENT_PATTERN = re.compile(r"^- Incident: `([^`]+)`$", re.MULTILINE)


class FeedbackError(ValueError):
    """Report invalid input or an unsafe issue update."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Record evidence in a skill's meta-feedback directory."
    )
    parser.add_argument("--payload", required=True, type=Path, help="JSON payload path")
    parser.add_argument(
        "--skills-root",
        type=Path,
        help="Agent skills root (default: AGENT_SKILLS_ROOT or ~/.agents/skills)",
    )
    return parser.parse_args()


def one_line(value: str, field: str) -> str:
    normalized = " ".join(value.split())
    if not normalized:
        raise FeedbackError(f"{field} must not be empty")
    return normalized


def load_payload(path: Path) -> dict[str, str]:
    try:
        raw: Any = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FeedbackError(f"cannot read payload: {error}") from error

    if not isinstance(raw, dict):
        raise FeedbackError("payload must be a JSON object")

    payload: dict[str, str] = {}
    for field in REQUIRED_FIELDS:
        value = raw.get(field)
        if not isinstance(value, str):
            raise FeedbackError(f"{field} must be a string")
        payload[field] = one_line(value, field)

    suggestion = raw.get("suggestion", "None")
    if suggestion is None or suggestion == "":
        suggestion = "None"
    if not isinstance(suggestion, str):
        raise FeedbackError("suggestion must be a string when provided")
    payload["suggestion"] = one_line(suggestion, "suggestion")
    return payload


def validate_slug(slug: str) -> None:
    if len(slug) > 63 or not SLUG_PATTERN.fullmatch(slug):
        raise FeedbackError(
            "skill must be a lowercase slug containing only letters, digits, and hyphens"
        )


def validate_identifier(value: str, field: str) -> None:
    if not IDENTIFIER_PATTERN.fullmatch(value):
        raise FeedbackError(
            f"{field} must be 1-128 characters using letters, digits, @, ., _, :, /, or -"
        )


def validate_title(title: str) -> None:
    if not title.isascii() or not TITLE_PATTERN.fullmatch(title):
        raise FeedbackError(
            "title must use ASCII letters, digits, single spaces, and hyphens only"
        )
    words = re.findall(r"[A-Za-z0-9]+", title)
    if not 4 <= len(words) <= 10:
        raise FeedbackError("title must contain four to ten words")
    if not title[0].isupper():
        raise FeedbackError("title must use sentence case")
    vague = VAGUE_TITLE_WORDS.intersection(word.lower() for word in words)
    if vague:
        raise FeedbackError(f"title contains a vague word: {sorted(vague)[0]}")


def title_filename(title: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return f"{slug}.md"


def read_skill_name(skill_file: Path) -> str:
    try:
        lines = skill_file.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise FeedbackError(f"cannot read target SKILL.md: {error}") from error
    if not lines or lines[0] != "---":
        raise FeedbackError("target SKILL.md must begin with YAML frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        raise FeedbackError("target SKILL.md has unterminated frontmatter") from error
    for line in lines[1:end]:
        match = re.fullmatch(r"name:\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s#]+))\s*", line)
        if match:
            return next(group for group in match.groups() if group is not None)
    raise FeedbackError("target SKILL.md frontmatter has no name")


def issue_frontmatter(text: str) -> dict[str, str]:
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise FeedbackError("existing feedback issue has no YAML frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        raise FeedbackError("existing feedback issue has unterminated frontmatter") from error
    values: dict[str, str] = {}
    for line in lines[1:end]:
        match = re.fullmatch(r"([a-z_]+):\s*\"([^\"]*)\"\s*", line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def atomic_write(path: Path, content: str) -> None:
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if path.exists():
            os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
        temporary = None
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def observation(payload: dict[str, str], when: str, revision: str) -> str:
    return "\n".join(
        (
            f"### {when} — {payload['agent']}",
            "",
            f"- Incident: `{payload['incident']}`",
            f"- Skill revision: `sha256:{revision}`",
            f"- Context: {payload['context']}",
            f"- Expected behavior: {payload['expected']}",
            f"- Observed behavior: {payload['observed']}",
            f"- Impact: {payload['impact']}",
            f"- Workaround: {payload['workaround']}",
            f"- Suggested direction: {payload['suggestion']}",
        )
    )


def new_issue(payload: dict[str, str], when: str, revision: str) -> str:
    return "\n".join(
        (
            "---",
            'schema: "skill-feedback/v1"',
            f'title: "{payload["title"]}"',
            f'skill: "{payload["skill"]}"',
            'status: "open"',
            f'created_at: "{when}"',
            "---",
            "",
            f"# {payload['title']}",
            "",
            "## Problem",
            "",
            payload["problem"],
            "",
            "## Observations",
            "",
            observation(payload, when, revision),
            "",
        )
    )


def record(payload: dict[str, str], skills_root: Path) -> tuple[str, Path]:
    validate_slug(payload["skill"])
    validate_title(payload["title"])
    validate_identifier(payload["agent"], "agent")
    validate_identifier(payload["incident"], "incident")

    target = skills_root.expanduser().resolve() / payload["skill"]
    skill_file = target / "SKILL.md"
    if not target.is_dir() or not skill_file.is_file():
        raise FeedbackError(f"target skill does not exist: {target}")
    actual_name = read_skill_name(skill_file)
    if actual_name != payload["skill"]:
        raise FeedbackError(
            f"target SKILL.md name is {actual_name!r}, expected {payload['skill']!r}"
        )

    feedback_dir = target / "meta-feedback"
    lock_digest = hashlib.sha256(str(feedback_dir).encode("utf-8")).hexdigest()[:20]
    lock_path = Path(tempfile.gettempdir()) / f"meta-feedback-{lock_digest}.lock"

    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        feedback_dir.mkdir(exist_ok=True)
        issue_path = feedback_dir / title_filename(payload["title"])
        matching_path: Path | None = None

        for candidate in sorted(feedback_dir.glob("*.md")):
            text = candidate.read_text(encoding="utf-8")
            if payload["incident"] in INCIDENT_PATTERN.findall(text):
                raise FeedbackError(
                    f"incident already recorded in {candidate.name}: {payload['incident']}"
                )
            metadata = issue_frontmatter(text)
            if metadata.get("title") == payload["title"]:
                matching_path = candidate

        if matching_path is not None and matching_path != issue_path:
            raise FeedbackError(
                f"matching title exists under noncanonical filename: {matching_path.name}"
            )

        revision = hashlib.sha256(skill_file.read_bytes()).hexdigest()
        when = timestamp()
        if issue_path.exists():
            existing = issue_path.read_text(encoding="utf-8")
            metadata = issue_frontmatter(existing)
            expected = {
                "schema": "skill-feedback/v1",
                "title": payload["title"],
                "skill": payload["skill"],
            }
            for field, value in expected.items():
                if metadata.get(field) != value:
                    raise FeedbackError(
                        f"existing issue has unexpected {field}: {metadata.get(field)!r}"
                    )
            updated = existing.rstrip() + "\n\n" + observation(payload, when, revision) + "\n"
            action = "appended"
        else:
            updated = new_issue(payload, when, revision)
            action = "created"

        atomic_write(issue_path, updated)
        return action, issue_path


def main() -> int:
    args = parse_args()
    try:
        payload = load_payload(args.payload)
        skills_root = args.skills_root
        if skills_root is None:
            skills_root = Path(
                os.environ.get("AGENT_SKILLS_ROOT", "~/.agents/skills")
            )
        action, issue_path = record(payload, skills_root)
    except FeedbackError as error:
        print(f"record_feedback.py: {error}", file=sys.stderr)
        return 2
    print(f"{action} {issue_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

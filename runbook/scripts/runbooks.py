#!/usr/bin/env python3
"""Manage lightweight, agent-owned runbook memory."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

DEFAULTS_DIR = Path(__file__).resolve().parent.parent / "references" / "default-runbooks"
ALLOWED_STATUSES = {"default", "draft", "active", "retired"}
SLUG_RE = re.compile(r"^[a-z0-9]+(?:[-_][a-z0-9]+)*$")


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage reusable runbook memory.")
    parser.add_argument("--runbooks-dir", help="Defaults to RUNBOOK_DIR, then $AGENT_HOME/runbooks, then ~/.agents/homes/runbook/runbooks.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init", help="Create the store and seed bundled defaults.").add_argument("--json", action="store_true")
    list_parser = commands.add_parser("list", help="List runbook summaries.")
    list_parser.add_argument("--no-defaults", action="store_true")
    list_parser.add_argument("--include-retired", action="store_true")
    list_parser.add_argument("--json", action="store_true")
    commands.add_parser("show", help="Print one runbook.").add_argument("slug")
    commands.add_parser("path", help="Print the store path or one runbook path.").add_argument("slug", nargs="?")
    capture = commands.add_parser("capture", help="Create a draft runbook.")
    capture.add_argument("slug")
    capture.add_argument("--summary", required=True)
    capture.add_argument("--trigger", action="append", default=[])
    capture.add_argument("--body")
    capture.add_argument("--force", action="store_true")
    rewrite = commands.add_parser("rewrite", help="Replace the canonical runbook body.")
    rewrite.add_argument("slug")
    rewrite.add_argument("--body")
    review = commands.add_parser("review", help="Append a consequential review note.")
    review.add_argument("slug")
    review.add_argument("--note")
    status = commands.add_parser("set-status", help="Set runbook lifecycle status.")
    status.add_argument("slug")
    status.add_argument("status", choices=sorted(ALLOWED_STATUSES - {"default"}))
    commands.add_parser("validate", help="Validate runbook metadata and filenames.").add_argument("--json", action="store_true")
    args = parser.parse_args()
    runbooks_dir = resolve_runbooks_dir(args.runbooks_dir)

    if args.command == "init":
        ensure_store(runbooks_dir)
        emit({"runbooks_dir": str(runbooks_dir), "seeded": seed_defaults(runbooks_dir)}, args.json, str(runbooks_dir))
    elif args.command == "list":
        ensure_store(runbooks_dir)
        if not args.no_defaults:
            seed_defaults(runbooks_dir)
        items = list_runbooks(runbooks_dir, args.include_retired)
        emit({"runbooks_dir": str(runbooks_dir), "runbooks": items}, args.json, "\n".join(f"{x['slug']}\t{x['status']}\t{x['summary']}" for x in items))
    elif args.command == "show":
        ensure_store(runbooks_dir)
        seed_defaults(runbooks_dir)
        print(existing_path(runbooks_dir, args.slug).read_text(encoding="utf-8"), end="")
    elif args.command == "path":
        ensure_store(runbooks_dir)
        print(runbook_path(runbooks_dir, args.slug))
    elif args.command == "capture":
        ensure_store(runbooks_dir)
        path = runbook_path(runbooks_dir, args.slug)
        if path.exists() and not args.force:
            fail(f"{path} already exists; pass --force only when replacement is intentional")
        body = args.body if args.body is not None else stdin_or(default_body(slugify(args.slug)))
        atomic_write(path, render_runbook(args.slug, args.summary, args.trigger, body))
        print(path)
    elif args.command == "rewrite":
        path = existing_path(runbooks_dir, args.slug)
        frontmatter, _ = split_frontmatter(path.read_text(encoding="utf-8"))
        atomic_write(path, join_frontmatter(set_scalar(frontmatter, "updated", today()), stdin_or(None, args.body, "rewrite requires --body or stdin")))
        print(path)
    elif args.command == "review":
        path = existing_path(runbooks_dir, args.slug)
        frontmatter, body = split_frontmatter(path.read_text(encoding="utf-8"))
        note = stdin_or(None, args.note, "review requires --note or stdin")
        atomic_write(path, join_frontmatter(set_scalar(frontmatter, "updated", today()), body.rstrip() + f"\n\n## Review {today()}\n\n{note.strip()}"))
        print(path)
    elif args.command == "set-status":
        path = existing_path(runbooks_dir, args.slug)
        frontmatter, body = split_frontmatter(path.read_text(encoding="utf-8"))
        if parse_frontmatter(frontmatter).get("status") == "default":
            fail("the bundled default runbook cannot be promoted or retired in place; copy it to a new slug")
        atomic_write(path, join_frontmatter(set_scalar(set_scalar(frontmatter, "status", args.status), "updated", today()), body))
        print(path)
    else:
        ensure_store(runbooks_dir)
        seed_defaults(runbooks_dir)
        report = validate_store(runbooks_dir)
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            for item in report["files"]:
                print(f"{'ok' if not item['errors'] else 'error'}\t{item['path']}")
                for error in item["errors"]:
                    print(f"  - {error}")
            print(f"{report['valid']} valid, {report['invalid']} invalid")
        return 1 if report["invalid"] else 0
    return 0


def resolve_runbooks_dir(value: str | None) -> Path:
    if value:
        return Path(value).expanduser().resolve()
    if value := os.environ.get("RUNBOOK_DIR"):
        return Path(value).expanduser().resolve()
    if value := os.environ.get("AGENT_HOME"):
        return (Path(value).expanduser() / "runbooks").resolve()
    return Path("~/.agents/homes/runbook/runbooks").expanduser().resolve()


def ensure_store(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)


def seed_defaults(directory: Path) -> list[str]:
    seeded = []
    for source in sorted(DEFAULTS_DIR.glob("*.md")):
        target = directory / source.name
        if not target.exists():
            shutil.copyfile(source, target)
            seeded.append(source.stem)
    return seeded


def list_runbooks(directory: Path, include_retired: bool) -> list[dict[str, Any]]:
    items = []
    for path in sorted(directory.glob("*.md")):
        attrs = parse_frontmatter(split_frontmatter(path.read_text(encoding="utf-8"))[0])
        if attrs.get("status", "draft") == "retired" and not include_retired:
            continue
        items.append({"slug": str(attrs.get("slug", path.stem)), "summary": str(attrs.get("summary", "(no summary)")), "triggers": attrs.get("triggers", []), "status": str(attrs.get("status", "draft")), "updated": attrs.get("updated"), "path": str(path)})
    return items


def validate_store(directory: Path) -> dict[str, Any]:
    files, seen, invalid = [], {}, 0
    for path in sorted(directory.glob("*.md")):
        errors: list[str] = []
        try:
            attrs = parse_frontmatter(split_frontmatter(path.read_text(encoding="utf-8"))[0])
        except ValueError as exc:
            attrs = {}
            errors.append(str(exc))
        slug, summary, status = attrs.get("slug"), attrs.get("summary"), attrs.get("status", "draft")
        if not isinstance(slug, str) or not slug:
            errors.append("missing required scalar: slug")
        elif not SLUG_RE.fullmatch(slug):
            errors.append("slug must contain lowercase letters, numbers, hyphens, or underscores")
        else:
            if path.stem != slug:
                errors.append(f"filename must be {slug}.md")
            if slug in seen:
                errors.append(f"duplicate slug also used by {seen[slug]}")
            seen[slug] = str(path)
        if not isinstance(summary, str) or not summary.strip():
            errors.append("missing required scalar: summary")
        if status not in ALLOWED_STATUSES:
            errors.append(f"status must be one of: {', '.join(sorted(ALLOWED_STATUSES))}")
        if "triggers" in attrs and not isinstance(attrs["triggers"], list):
            errors.append("triggers must be a YAML list")
        invalid += bool(errors)
        files.append({"path": str(path), "slug": slug, "errors": errors})
    return {"runbooks_dir": str(directory), "valid": len(files) - invalid, "invalid": invalid, "files": files}


def runbook_path(directory: Path, slug: str | None) -> Path:
    if slug is None:
        return directory
    slug = slugify(slug)
    if not slug:
        fail("runbook slug cannot be empty")
    return directory / f"{slug}.md"


def existing_path(directory: Path, slug: str) -> Path:
    path = runbook_path(directory, slug)
    if not path.exists():
        fail(f"{path} does not exist")
    return path


def render_runbook(slug: str, summary: str, triggers: list[str], body: str) -> str:
    slug = slugify(slug)
    if not slug:
        fail("runbook slug cannot be empty")
    trigger_lines = "\n".join(f"  - {json.dumps(item, ensure_ascii=False)}" for item in triggers) or "  - Add representative triggers after the first real use."
    frontmatter = f"slug: {slug}\nsummary: {json.dumps(summary.strip(), ensure_ascii=False)}\ntriggers:\n{trigger_lines}\nstatus: draft\ncreated: {today()}\nupdated: {today()}"
    return join_frontmatter(frontmatter, f"# {titleize(slug)}\n\n{body.strip() or default_body(slug)}")


def split_frontmatter(text: str) -> tuple[str, str]:
    text = text.replace("\r\n", "\n")
    if not text.startswith("---\n"):
        raise ValueError("file must begin with YAML frontmatter")
    end = text.find("\n---\n", 4)
    if end == -1:
        raise ValueError("frontmatter is missing its closing --- line")
    return text[4:end], text[end + 5:]


def join_frontmatter(frontmatter: str, body: str) -> str:
    return f"---\n{frontmatter.strip()}\n---\n\n{body.strip()}\n"


def parse_frontmatter(frontmatter: str) -> dict[str, Any]:
    attrs: dict[str, Any] = {}
    active = None
    for line in frontmatter.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^\s{2,}-\s+(.*)$", line)
        if match and active:
            attrs.setdefault(active, []).append(parse_scalar(match.group(1)))
            continue
        match = re.match(r"^([A-Za-z0-9_-]+):(?:\s*(.*))?$", line)
        if not match:
            active = None
            continue
        key, value = match.group(1), (match.group(2) or "").strip()
        attrs[key], active = (parse_scalar(value), None) if value else ([], key)
    return attrs


def parse_scalar(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] == '"':
        try:
            return str(json.loads(value))
        except json.JSONDecodeError:
            pass
    return value[1:-1].replace("''", "'") if len(value) >= 2 and value[0] == value[-1] == "'" else value


def set_scalar(frontmatter: str, key: str, value: str) -> str:
    replacement = f"{key}: {value}"
    pattern = re.compile(rf"^{re.escape(key)}:.*$", re.MULTILINE)
    return pattern.sub(replacement, frontmatter, count=1) if pattern.search(frontmatter) else frontmatter.rstrip() + "\n" + replacement


def stdin_or(default: str | None, value: str | None = None, message: str | None = None) -> str:
    if value is not None:
        return value
    if not sys.stdin.isatty() and (text := sys.stdin.read()).strip():
        return text
    if message:
        fail(message)
    return default or ""


def default_body(slug: str) -> str:
    return f"""## Outcome

Describe what useful completion looks like.

## Sources Of Truth

List where current facts must be checked instead of remembered here.

## Approach

1. Describe the learned procedure after the first meaningful run.
2. Include judgment branches only where they materially change execution.

## Done When

State the completion checks and durable outputs.

## Review History

- Created from the first meaningful encounter with `{slug}`."""


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(name, path)
    except Exception:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9_-]+", "-", value.strip().lower()).strip("-_")


def titleize(slug: str) -> str:
    return " ".join(part.capitalize() for part in re.split(r"[-_]+", slug) if part)


def today() -> str:
    return dt.date.today().isoformat()


def emit(payload: dict[str, Any], as_json: bool, text: str) -> None:
    print(json.dumps(payload, indent=2) if as_json else text)


def fail(message: str) -> None:
    raise SystemExit(message)


if __name__ == "__main__":
    raise SystemExit(main())

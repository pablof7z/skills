#!/usr/bin/env python3
"""Report hand-maintained code files that cross repository LOC limits."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


CODE_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".go",
    ".h",
    ".hpp",
    ".java",
    ".js",
    ".jsx",
    ".kt",
    ".kts",
    ".m",
    ".mm",
    ".py",
    ".rb",
    ".rs",
    ".sh",
    ".swift",
    ".ts",
    ".tsx",
}
SCRIPT_SHEBANGS = ("#!",)
EXCLUDED_PARTS = {"node_modules", "vendor", "target", ".build"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--soft", type=int, default=300)
    parser.add_argument("--hard", type=int, default=600)
    return parser.parse_args()


def tracked_files(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [root / raw.decode() for raw in result.stdout.split(b"\0") if raw]


def is_code_file(path: Path) -> bool:
    if path.suffix.lower() in CODE_SUFFIXES:
        return True
    try:
        first_line = path.open(encoding="utf-8").readline()
    except (OSError, UnicodeDecodeError):
        return False
    return first_line.startswith(SCRIPT_SHEBANGS)


def line_count(path: Path) -> int:
    with path.open("rb") as handle:
        return sum(1 for _ in handle)


def main() -> int:
    args = parse_args()
    if args.soft <= 0 or args.hard <= args.soft:
        raise SystemExit("limits must satisfy 0 < soft < hard")

    root = Path(__file__).resolve().parents[1]
    soft: list[tuple[int, Path]] = []
    hard: list[tuple[int, Path]] = []

    for path in tracked_files(root):
        relative = path.relative_to(root)
        if not path.is_file() or EXCLUDED_PARTS.intersection(relative.parts):
            continue
        if not is_code_file(path):
            continue
        count = line_count(path)
        if count > args.hard:
            hard.append((count, relative))
        elif count > args.soft:
            soft.append((count, relative))

    for count, path in sorted(soft, reverse=True):
        print(f"SOFT {count:4d} {path}")
    for count, path in sorted(hard, reverse=True):
        print(f"HARD {count:4d} {path}")

    if hard:
        print(f"\n{len(hard)} file(s) exceed the {args.hard}-LOC hard limit.")
        return 1
    if soft:
        print(f"\n{len(soft)} file(s) exceed the {args.soft}-LOC soft limit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

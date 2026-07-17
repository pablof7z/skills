#!/usr/bin/env python3
"""Implement the stateful `tts-menu queue` command family."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import uuid

state_dir = Path(sys.argv[1])
argv = sys.argv[2:]
items_dir = state_dir / "items"
operations_dir = state_dir / "operations"
lock_path = state_dir / "operations.flock"
DEFAULT_LIMIT = 20
MAX_LIMIT = 100


def fail(message, code=1):
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(code)


def emit(value):
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True))


def duration(value):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smh]?)", value.strip(), re.IGNORECASE)
    if not match:
        raise argparse.ArgumentTypeError("use a positive duration such as 30s, 5m, or 1h")
    amount = float(match.group(1))
    multiplier = {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2).lower()]
    seconds = amount * multiplier
    if seconds <= 0:
        raise argparse.ArgumentTypeError("duration must be positive")
    return seconds


def describe_duration(seconds):
    if seconds >= 3600 and seconds % 3600 == 0:
        amount, unit = seconds / 3600, "hour"
    elif seconds >= 60 and seconds % 60 == 0:
        amount, unit = seconds / 60, "minute"
    else:
        amount, unit = seconds, "second"
    rendered = str(int(amount)) if amount.is_integer() else f"{amount:g}"
    return f"{rendered} {unit}{'' if amount == 1 else 's'}"


def compact_duration(seconds):
    if seconds >= 3600 and seconds % 3600 == 0:
        return f"{seconds / 3600:g}h"
    if seconds >= 60 and seconds % 60 == 0:
        return f"{seconds / 60:g}m"
    return f"{seconds:g}s"


def read_item(item_id):
    path = items_dir / f"{item_id}.json"
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except FileNotFoundError:
        fail(f"TTS item not found: {item_id}", 2)
    except (OSError, ValueError) as error:
        fail(f"could not read TTS item {item_id}: {error}")
    if not isinstance(value, dict) or value.get("id") != item_id:
        fail(f"invalid TTS item record: {item_id}")
    return value


def all_items():
    result = []
    if not items_dir.is_dir():
        return result
    for path in items_dir.glob("*.json"):
        try:
            with path.open(encoding="utf-8") as handle:
                value = json.load(handle)
            if isinstance(value, dict) and value.get("id"):
                result.append(value)
        except (OSError, ValueError):
            continue
    return result


def archive_affected_items(requested_ids):
    requested = sorted(set(requested_ids))
    requested_items = [read_item(item_id) for item_id in requested]
    by_id = {item["id"]: item for item in all_items()}
    by_id.update({item["id"]: item for item in requested_items})
    affected = set(requested)
    changed = True
    while changed:
        changed = False
        for item in by_id.values():
            if item.get("parent_item_id") in affected and item["id"] not in affected:
                affected.add(item["id"])
                changed = True
    return [by_id[item_id] for item_id in sorted(affected)]


def apply_archive_state(item, archived, reason, operation_actor, now):
    item["is_archived"] = archived
    item["archived_at"] = now if archived else None
    item["archive_reason"] = reason if archived else None
    item["archived_by"] = operation_actor if archived else None
    if archived and item.get("status") in ("queued", "playing", "paused"):
        item["status"] = "interrupted"
        item["completed_at"] = now
        item["playback_offset"] = None
        item["return_to_playback_offset"] = None
        item["playback_initiator"] = None
        if not (item.get("parent_item_id") and item.get("attachment_id")):
            item["is_unheard"] = True
    return item


def atomic_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.stem}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class operation_lock:
    def __init__(self, exclusive=True):
        self.exclusive = exclusive

    def __enter__(self):
        state_dir.mkdir(parents=True, exist_ok=True)
        self.handle = lock_path.open("a+")
        mode = fcntl.LOCK_EX if self.exclusive else fcntl.LOCK_SH
        fcntl.flock(self.handle.fileno(), mode)
        return self

    def __exit__(self, *_):
        fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        self.handle.close()


def actor(args):
    return args.actor or os.environ.get("TTS_AGENT_NAME") or os.environ.get("TENEX_AGENT_NAME") or None


def audit(kind, source_ids, replacement_ids, reason, operation_actor):
    operation_id = str(uuid.uuid4())
    value = {
        "id": operation_id,
        "kind": kind,
        "source_ids": source_ids,
        "replacement_ids": replacement_ids,
        "reason": reason,
        "actor": operation_actor,
        "created_at": int(time.time()),
    }
    atomic_write(operations_dir / f"{operation_id}.json", value)
    return operation_id


parser = argparse.ArgumentParser(prog="tts-menu queue")
commands = parser.add_subparsers(dest="command", required=True)

list_parser = commands.add_parser("list")
list_parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
list_parser.add_argument("--offset", type=int, default=0)
list_parser.add_argument("--mine", action="store_true")
list_parser.add_argument("--agent-name")
list_parser.add_argument("--session-id")
list_parser.add_argument("--archived", action="store_true", help="show only archived items")
list_parser.add_argument("--all", action="store_true", help="include active and archived items")

get_parser = commands.add_parser("get")
get_parser.add_argument("id")

wait_parser = commands.add_parser("wait")
wait_parser.add_argument("id")
wait_parser.add_argument("--timeout", type=duration, required=True)
wait_parser.add_argument("--poll-interval", type=float, default=0.25, help=argparse.SUPPRESS)

archive_parser = commands.add_parser("archive")
archive_parser.add_argument("ids", nargs="+")
archive_parser.add_argument("--reason", required=True)
archive_parser.add_argument("--actor")

restore_parser = commands.add_parser("restore")
restore_parser.add_argument("ids", nargs="+")
restore_parser.add_argument("--reason", default="Restored to the active queue.")
restore_parser.add_argument("--actor")

supersede_parser = commands.add_parser("supersede")
supersede_parser.add_argument("ids", nargs="+")
supersede_parser.add_argument("--superseded-by", dest="replacements", action="append", required=True)
supersede_parser.add_argument("--reason", required=True)
supersede_parser.add_argument("--actor")

args = parser.parse_args(argv)

if args.command == "list":
    if args.limit < 1 or args.limit > MAX_LIMIT:
        fail(f"--limit must be between 1 and {MAX_LIMIT}")
    if args.offset < 0:
        fail("--offset must be non-negative")
    if args.archived and args.all:
        fail("--archived and --all cannot be combined")
    with operation_lock(exclusive=False):
        values = all_items()
    if args.archived:
        values = [item for item in values if item.get("is_archived") is True]
    elif not args.all:
        values = [item for item in values if item.get("is_archived") is not True]
    if args.mine:
        mine_agent = args.agent_name or os.environ.get("TTS_AGENT_NAME") or os.environ.get("TENEX_AGENT_NAME")
        mine_session = args.session_id or os.environ.get("TTS_SESSION_ID") or os.environ.get("TENEX_EDGE_SESSION_ID") or os.environ.get("CODEX_THREAD_ID") or os.environ.get("CLAUDE_SESSION_ID") or os.environ.get("WTG_SESSION_ID")
        if not mine_agent and not mine_session:
            fail("--mine requires an identifiable agent or session in the environment")
        values = [
            item for item in values
            if (mine_session and item.get("session_id") == mine_session)
            or (mine_agent and item.get("agent_name") == mine_agent)
        ]
    else:
        if args.agent_name:
            values = [item for item in values if item.get("agent_name") == args.agent_name]
        if args.session_id:
            values = [item for item in values if item.get("session_id") == args.session_id]
    values.sort(key=lambda item: (item.get("created_at", 0), item.get("id", "")), reverse=True)
    total = len(values)
    page = values[args.offset:args.offset + args.limit]
    next_offset = args.offset + len(page) if args.offset + len(page) < total else None
    emit({
        "items": page,
        "pagination": {
            "limit": args.limit,
            "offset": args.offset,
            "count": len(page),
            "total": total,
            "next_offset": next_offset,
        },
    })
    raise SystemExit(0)

if args.command == "get":
    with operation_lock(exclusive=False):
        value = read_item(args.id)
    emit(value)
    raise SystemExit(0)

if args.command == "wait":
    if args.poll_interval <= 0:
        fail("--poll-interval must be positive")
    deadline = time.monotonic() + args.timeout
    while True:
        with operation_lock(exclusive=False):
            item = read_item(args.id)
        questions = item.get("questions") or []
        for question in questions:
            response = question.get("response")
            if not isinstance(response, dict):
                continue
            singular = response.get("suggestion_id")
            plural = response.get("suggestion_ids")
            if not isinstance(plural, list):
                plural = [singular] if singular else []
                response["suggestion_ids"] = plural
            if not singular and plural:
                response["suggestion_id"] = plural[0]
        question_status = item.get("question_status")
        playback_status = item.get("status")
        if questions and all(question.get("status") != "pending" for question in questions):
            answered = [question for question in questions if question.get("status") == "answered"]
            attachment_paths = []
            for question in questions:
                response = question.get("response") or {}
                for attachment in response.get("attachments") or []:
                    path = attachment.get("source_file") or attachment.get("path")
                    if path:
                        attachment_paths.append(path)
            emit({
                "id": item["id"],
                "status": "answered" if answered else "skipped",
                "questions_preamble": item.get("questions_preamble"),
                "questions": questions,
                "attachments": item.get("attachments") or [],
                "answer_attachment_paths": attachment_paths,
                "reason": item.get("archive_reason"),
                "superseded_by": item.get("superseded_by") or [],
            })
            raise SystemExit(0)
        if question_status and question_status != "pending":
            response = item.get("response") or {}
            singular = response.get("suggestion_id")
            plural = response.get("suggestion_ids")
            if not isinstance(plural, list):
                plural = [singular] if singular else []
                response["suggestion_ids"] = plural
            if not singular and plural:
                response["suggestion_id"] = plural[0]
            answer_attachment_paths = [
                attachment.get("source_file") or attachment.get("path")
                for attachment in response.get("attachments") or []
                if attachment.get("source_file") or attachment.get("path")
            ]
            emit({
                "id": item["id"],
                "status": question_status,
                "answer": response.get("answer"),
                "suggestion_index": response.get("suggestion_index"),
                "suggestion_id": response.get("suggestion_id"),
                "suggestion_ids": response.get("suggestion_ids") or [],
                "modified": response.get("modified"),
                "response": response,
                "answer_attachment_paths": answer_attachment_paths,
                "reason": item.get("archive_reason"),
                "superseded_by": item.get("superseded_by") or [],
            })
            raise SystemExit(0)
        if not question_status and playback_status in ("generated", "played", "failed"):
            emit({"id": item["id"], "status": playback_status})
            raise SystemExit(0)
        if time.monotonic() >= deadline:
            waited = describe_duration(args.timeout)
            next_wait = compact_duration(args.timeout)
            menu_command = os.environ.get("TTS_MENU_SELF", "<skill-dir>/scripts/tts-menu")
            wait_command = f"{menu_command} queue wait {item['id']} --timeout {next_wait}"
            emit({
                "id": item["id"],
                "status": "pending",
                "waited_seconds": args.timeout,
                "guidance": (
                    f"The user hasn't replied after {waited}. Decide whether their answer is needed now. "
                    f"To block for another bounded interval, run: {wait_command}"
                ),
                "wait_command": wait_command,
            })
            raise SystemExit(0)
        time.sleep(args.poll_interval)

now = int(time.time())
operation_actor = actor(args)

if args.command == "archive":
    with operation_lock():
        items = archive_affected_items(args.ids)
        for item in items:
            apply_archive_state(item, True, args.reason, operation_actor, now)
            atomic_write(items_dir / f"{item['id']}.json", item)
        affected_ids = [item["id"] for item in items]
        operation_id = audit("archive", affected_ids, [], args.reason, operation_actor)
    emit({"operation_id": operation_id, "status": "archived", "ids": affected_ids, "reason": args.reason})
    raise SystemExit(0)

if args.command == "restore":
    with operation_lock():
        items = archive_affected_items(args.ids)
        for item in items:
            apply_archive_state(item, False, None, operation_actor, now)
            atomic_write(items_dir / f"{item['id']}.json", item)
        affected_ids = [item["id"] for item in items]
        operation_id = audit("restore", affected_ids, [], args.reason, operation_actor)
    emit({"operation_id": operation_id, "status": "restored", "ids": affected_ids})
    raise SystemExit(0)

if args.command == "supersede":
    if len(set(args.ids)) != len(args.ids) or len(set(args.replacements)) != len(args.replacements):
        fail("source and replacement ids must not contain duplicates")
    if set(args.ids) & set(args.replacements):
        fail("an item cannot supersede itself")
    with operation_lock():
        sources = [read_item(item_id) for item_id in args.ids]
        replacements = [read_item(item_id) for item_id in args.replacements]
        for item in sources:
            if item.get("kind") != "question" or item.get("question_status") != "pending":
                fail(f"only pending questions can be superseded: {item['id']}", 3)
        graph = {item["id"]: list(item.get("superseded_by") or []) for item in all_items()}
        for source_id in args.ids:
            graph[source_id] = list(args.replacements)

        def reaches(target, start):
            pending = [start]
            visited = set()
            while pending:
                current = pending.pop()
                if current == target:
                    return True
                if current in visited:
                    continue
                visited.add(current)
                pending.extend(graph.get(current, []))
            return False

        for source_id in args.ids:
            for replacement_id in args.replacements:
                if reaches(source_id, replacement_id):
                    fail(f"supersession would create a cycle through {replacement_id}", 3)
        for item in sources:
            item["question_status"] = "superseded"
            item["superseded_by"] = args.replacements
            apply_archive_state(item, True, args.reason, operation_actor, now)
            atomic_write(items_dir / f"{item['id']}.json", item)
        operation_id = audit("supersede", args.ids, args.replacements, args.reason, operation_actor)
    emit({
        "operation_id": operation_id,
        "status": "superseded",
        "ids": args.ids,
        "reason": args.reason,
        "superseded_by": args.replacements,
    })
    raise SystemExit(0)

#!/usr/bin/env python3
"""Recover interrupted native-player queue items."""

import json
import os
import sys
import tempfile
import time

items_dir = os.path.join(sys.argv[1], "items")
if not os.path.isdir(items_dir):
    raise SystemExit(0)

for name in os.listdir(items_dir):
    if not name.endswith(".json"):
        continue
    path = os.path.join(items_dir, name)
    try:
        with open(path, encoding="utf-8") as handle:
            item = json.load(handle)
    except (OSError, ValueError):
        continue
    if item.get("status") not in ("playing", "paused"):
        continue
    item["status"] = "queued" if os.path.isfile(item.get("output_file", "")) else "failed"
    item["started_at"] = None
    item["completed_at"] = None if item["status"] == "queued" else int(time.time())
    item["error"] = None if item["status"] == "queued" else "Audio file is no longer available."
    fd, temporary = tempfile.mkstemp(prefix=".tts-item-", dir=items_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(item, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

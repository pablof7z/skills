#!/usr/bin/env python3
"""Render native-player queue status for the tts-menu command."""

import json
import os
import sys

state_dir = sys.argv[1]
json_output = sys.argv[2] == "1"
items_dir = os.path.join(state_dir, "items")

items = []
if os.path.isdir(items_dir):
    for name in os.listdir(items_dir):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(items_dir, name), encoding="utf-8") as handle:
                items.append(json.load(handle))
        except (OSError, ValueError):
            pass

items.sort(key=lambda item: (item.get("created_at", 0), item.get("id", "")))
queued = [item for item in items if item.get("status") == "queued"]
recent = [item for item in items if item.get("status") in ("played", "failed")]
recent.sort(key=lambda item: item.get("created_at", 0), reverse=True)

def live_pid(path):
    try:
        with open(path, encoding="utf-8") as handle:
            pid = int(handle.readline().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, TypeError, ValueError):
        return None

menu_pid = live_pid(os.path.join(state_dir, "menu.pid"))
legacy_owner_pid = live_pid(os.path.join(state_dir, "speech.lock", "owner"))
recorded_current = next((item for item in items if item.get("status") in ("playing", "paused")), None)
current = recorded_current if menu_pid else None
interrupted = recorded_current if recorded_current and not menu_pid else None
state = current.get("status") if current else (
    "interrupted" if interrupted else (
        "queued" if queued else ("playing" if legacy_owner_pid else "idle")
    )
)

result = {
    "state": state,
    "current": current,
    "interrupted": interrupted,
    "queued": queued,
    "recent": recent[:30],
    "menu_pid": menu_pid,
    "legacy_owner_pid": legacy_owner_pid,
}

if json_output:
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(0)

print(f"state: {state}")
if current:
    agent = current.get("agent_name") or current.get("harness") or "Unknown agent"
    text = " ".join((current.get("subject") or current.get("text", "")).split())
    if len(text) > 90:
        text = text[:87] + "..."
    print(f"current: {agent} - {text}")
elif legacy_owner_pid:
    print(f"current: fallback playback pid {legacy_owner_pid}")
elif interrupted:
    print("current: interrupted native playback")
print(f"queued: {len(queued)}")
print(f"recent: {len(recent)}")
if menu_pid:
    print(f"menu: pid {menu_pid}")

"""Harness-specific validation for WorktreeGuard's regression probes."""

from __future__ import annotations

from typing import Any


def denial_decision(harness: str, body: dict[str, Any]) -> tuple[str, str]:
    if harness == "grok":
        unexpected = set(body) - {"decision", "reason"}
        if unexpected or body.get("decision") not in {"allow", "deny"}:
            return "error", (
                f"invalid Grok hook response keys/decision: {sorted(unexpected)}"
            )
        return ("deny" if body.get("decision") == "deny" else "allow"), ""

    unexpected = set(body) - {"hookSpecificOutput"}
    output = body.get("hookSpecificOutput")
    if unexpected or not isinstance(output, dict):
        return "error", f"invalid {harness} hook response keys: {sorted(unexpected)}"
    output_keys = {
        "hookEventName", "permissionDecision", "permissionDecisionReason",
    }
    if set(output) - output_keys:
        return "error", f"invalid {harness} hookSpecificOutput keys: {sorted(output)}"
    if output.get("hookEventName") != "PreToolUse":
        return "error", f"invalid {harness} hookEventName"
    decision = output.get("permissionDecision")
    if decision not in {"allow", "deny", "ask"}:
        return "error", f"invalid {harness} permissionDecision"
    return str(decision), ""

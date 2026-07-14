---
type: episode-card
date: 2026-07-14
session: b9fc7038-82a9-471c-b5bc-438fc1890d3c
transcript: /Users/pablofernandez/.claude/projects/-Users-pablofernandez-Work-skills--claude-worktrees-tts-windowed-mode/b9fc7038-82a9-471c-b5bc-438fc1890d3c.jsonl
salience: root-cause
status: active
subjects:
  - window-position-drift
  - screen-inset-clamp
  - live-resize
supersedes:
  - 2026-07-14-b9fc703882a9-e3224aba-3-windowed-mode-positioning-invariant-position-once
related_claims: []
source_lines:
  - 1845-1850
  - 2040-2043
  - 1858-1867
captured_at: 2026-07-14T11:18:03Z
---

# Episode: Windowed-mode position drift fixed — two distinct root causes

## Prior State

In windowed mode, the player window drifted position on every new TTS item arrival, and a screen-inset clamp (clampCurrentFrameToVisibleScreen) wired to NSWindow.didEndLiveResizeNotification fired on native resize-drag release, snapping the frame to HUD-placement constraints.

## Trigger

Testing revealed the windowed player moved unexpectedly during playback and after resize. A subagent audit (Engineer) independently found the screen-clamp bug.

## Decision

Windowed mode now positions the window only once on first show and never touches it again. The screen-inset clamp is gated to floating HUD mode only, not windowed mode. Mode conditionals consolidated into a single usesFloatingHUD property.

## Consequences

- Native resize-drag in windowed mode preserves user's chosen frame
- No repositioning on new TTS items in windowed mode
- clampCurrentFrameToVisibleScreen no longer fires for windowed-mode live resize
- Scattered windowedMode conditionals refactored into documented usesFloatingHUD property

## Open Tail

*(none)*

## Evidence

- transcript lines 1845-1850
- transcript lines 2040-2043
- transcript lines 1858-1867

## Conversation

- Cleaned transcript (verbatim user words, abbreviated agent replies): [`transcripts/2026-07-14-b9fc703882a9-e3224aba-3-windowed-mode-position-drift-fixed-two.json`](transcripts/2026-07-14-b9fc703882a9-e3224aba-3-windowed-mode-position-drift-fixed-two.json)
- Raw transcript (verbatim user words, full agent replies): [`transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-3-windowed-mode-position-drift-fixed-two.json`](transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-3-windowed-mode-position-drift-fixed-two.json)

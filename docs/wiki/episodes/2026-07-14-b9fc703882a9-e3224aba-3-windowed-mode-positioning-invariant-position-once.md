---
type: episode-card
date: 2026-07-14
session: b9fc7038-82a9-471c-b5bc-438fc1890d3c
transcript: /Users/pablofernandez/.claude/projects/-Users-pablofernandez-Work-skills--claude-worktrees-tts-windowed-mode/b9fc7038-82a9-471c-b5bc-438fc1890d3c.jsonl
salience: product
status: superseded
subjects:
  - windowed-mode
  - position-drift
  - screen-clamp
  - hud-placement
supersedes: []
related_claims: []
source_lines:
  - 932-1011
  - 1839-1867
  - 2040-2046
captured_at: 2026-07-14T10:57:49Z
---

# Episode: Windowed mode positioning invariant: position once, never reposition on playback

## Prior State

HUD mode repositioned the panel on every playback state change and clamped the frame to visible screen insets on live-resize end. These HUD-specific behaviors were also firing in windowed mode, causing the user's window to jump position each time a new TTS item started playing.

## Trigger

User feedback that the windowed player drifted position. Root-cause analysis found two causes: (1) positionPanel called on every refresh/showPlayer in windowed mode, (2) clampCurrentFrameToVisibleScreen wired to didEndLiveResizeNotification for both modes, running HUD screen-inset clamping on native window resize.

## Decision

Windowed mode now positions the window only once on first show and never touches it again. Screen-inset clamping is gated to HUD mode only (usesFloatingHUD). Mode checks consolidated into a single usesFloatingHUD property.

## Consequences

- Windowed mode window stays where the user puts it across playback events
- Native resize handle no longer fights with HUDPlacement frame clamping
- usesFloatingHUD property centralizes all mode-gating logic that was previously scattered across individual windowedMode boolean checks
- HUD mode retains its auto-positioning and screen-clamp behavior unchanged

## Open Tail

*(none)*

## Evidence

- transcript lines 932-1011
- transcript lines 1839-1867
- transcript lines 2040-2046

## Conversation

- Cleaned transcript (verbatim user words, abbreviated agent replies): [`transcripts/2026-07-14-b9fc703882a9-e3224aba-3-windowed-mode-positioning-invariant-position-once.json`](transcripts/2026-07-14-b9fc703882a9-e3224aba-3-windowed-mode-positioning-invariant-position-once.json)
- Raw transcript (verbatim user words, full agent replies): [`transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-3-windowed-mode-positioning-invariant-position-once.json`](transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-3-windowed-mode-positioning-invariant-position-once.json)

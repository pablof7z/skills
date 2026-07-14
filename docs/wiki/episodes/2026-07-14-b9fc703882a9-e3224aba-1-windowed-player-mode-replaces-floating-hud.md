---
type: episode-card
date: 2026-07-14
session: b9fc7038-82a9-471c-b5bc-438fc1890d3c
transcript: /Users/pablofernandez/.claude/projects/-Users-pablofernandez-Work-skills--claude-worktrees-tts-windowed-mode/b9fc7038-82a9-471c-b5bc-438fc1890d3c.jsonl
salience: product
status: active
subjects:
  - tts-windowed-mode
  - floating-hud
  - menu-bar-popover
supersedes:
  - 2026-07-14-b9fc703882a9-e3224aba-2-menu-bar-popover-removed-replaced-with
related_claims: []
source_lines:
  - 155-159
  - 1633-1731
  - 1839-1850
  - 2040-2046
captured_at: 2026-07-14T11:18:03Z
---

# Episode: Windowed player mode replaces floating-HUD-only TTS presentation

## Prior State

TTS player existed only as a borderless floating HUD panel (.nonactivatingPanel, .floating level). Menu bar click opened an NSPopover with a full SwiftUI QueueView showing queue and history.

## Trigger

Pablo requested a windowed presentation mode via GitHub issue #100, overriding echo's 'don't implement yet' directive with explicit go-ahead to build.

## Decision

Added a windowed mode toggle: when enabled, the speaking panel becomes a regular NSWindow with native title bar, resize handle, and Dock presence. Added idle history list and project filter. Removed the menu-bar popover's QueueView/ItemRow/MetadataLine entirely; both click types now open a small settings dropdown (Show/Hide Player, Windowed/HUD toggle, Pause All). SwiftUI is no longer imported by TTSMenuBarApp.swift.

## Consequences

- Windowed mode persists via isWindowedModeEnabled in HUDPreferences
- Native window close, resize, and drag are available in windowed mode
- Menu bar popover with full queue list is historical — replaced by minimal dropdown
- History list styled as plain native SwiftUI List following system appearance instead of forced dark-mode glass HUD
- usesFloatingHUD property consolidates scattered mode conditionals

## Open Tail

- Project filter mentioned in issue #100 but implementation status unclear from transcript

## Evidence

- transcript lines 155-159
- transcript lines 1633-1731
- transcript lines 1839-1850
- transcript lines 2040-2046

## Conversation

- Cleaned transcript (verbatim user words, abbreviated agent replies): [`transcripts/2026-07-14-b9fc703882a9-e3224aba-1-windowed-player-mode-replaces-floating-hud.json`](transcripts/2026-07-14-b9fc703882a9-e3224aba-1-windowed-player-mode-replaces-floating-hud.json)
- Raw transcript (verbatim user words, full agent replies): [`transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-1-windowed-player-mode-replaces-floating-hud.json`](transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-1-windowed-player-mode-replaces-floating-hud.json)

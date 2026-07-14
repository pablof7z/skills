---
type: episode-card
date: 2026-07-14
session: b9fc7038-82a9-471c-b5bc-438fc1890d3c
transcript: /Users/pablofernandez/.claude/projects/-Users-pablofernandez-Work-skills--claude-worktrees-tts-windowed-mode/b9fc7038-82a9-471c-b5bc-438fc1890d3c.jsonl
salience: reversal
status: superseded
subjects:
  - menu-bar
  - popover-removal
  - queueview
  - status-item
supersedes: []
related_claims: []
source_lines:
  - 1633-1650
  - 1715-1731
  - 1759-1770
  - 1916-1921
captured_at: 2026-07-14T10:57:49Z
---

# Episode: Menu bar popover removed, replaced with simple dropdown menu

## Prior State

Clicking the menu bar status item opened an NSPopover containing a full SwiftUI QueueView with now-playing section, up-next queue list, history, and footer controls. Both left-click and right-click had separate handling paths.

## Trigger

With windowed mode now providing a persistent history list and player surface, the popover's queue/history list became redundant. User directive to simplify the menu bar interaction.

## Decision

Removed the entire QueueView, ItemRow, and MetadataLine SwiftUI structs and the NSPopover. Both click types now open one small native NSMenu dropdown with only: Show/Hide Player, Windowed/HUD toggle, and Pause All.

## Consequences

- ~270 lines of SwiftUI view code deleted from TTSMenuBarApp.swift
- Menu bar status item no longer hosts a popover; all queue/history interaction moved to the windowed player
- Simpler click handling: single unified menu for both left and right click
- SwiftUI import in TTSMenuBarApp.swift may now be unused (was only for QueueView)

## Open Tail

- Whether SwiftUI can be fully removed from TTSMenuBarApp.swift now that QueueView is gone

## Evidence

- transcript lines 1633-1650
- transcript lines 1715-1731
- transcript lines 1759-1770
- transcript lines 1916-1921

## Conversation

- Cleaned transcript (verbatim user words, abbreviated agent replies): [`transcripts/2026-07-14-b9fc703882a9-e3224aba-2-menu-bar-popover-removed-replaced-with.json`](transcripts/2026-07-14-b9fc703882a9-e3224aba-2-menu-bar-popover-removed-replaced-with.json)
- Raw transcript (verbatim user words, full agent replies): [`transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-2-menu-bar-popover-removed-replaced-with.json`](transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-2-menu-bar-popover-removed-replaced-with.json)

---
type: episode-card
date: 2026-07-14
session: b9fc7038-82a9-471c-b5bc-438fc1890d3c
transcript: /Users/pablofernandez/.claude/projects/-Users-pablofernandez-Work-skills--claude-worktrees-tts-windowed-mode/b9fc7038-82a9-471c-b5bc-438fc1890d3c.jsonl
salience: root-cause
status: active
subjects:
  - dock-icon
  - lsuielement
  - activation-policy
  - info-plist
supersedes: []
related_claims: []
source_lines:
  - 1303-1304
  - 1395-1473
  - 1553-1607
  - 2042-2044
captured_at: 2026-07-14T11:18:03Z
---

# Episode: Static LSUIElement=true in Info.plist was root cause of missing Dock icon

## Prior State

App's Info.plist had LSUIElement=true hardcoded, pinning the app as a background UIElement regardless of runtime NSApp.setActivationPolicy(.regular) calls. Additionally, activation policy was checked before the window was visible, causing an ordering bug.

## Trigger

After deploying windowed mode, Dock icon did not appear despite setActivationPolicy(.regular) succeeding internally (confirmed via debug logging showing now=0=.regular).

## Decision

Removed the static LSUIElement key from the Info.plist template in the tts-menu build script. Runtime activation policy now controls Dock visibility: .regular when windowed mode + panel visible, .accessory otherwise. Added NSApp.activate(ignoringOtherApps: true) nudge after policy change since LaunchServices frequently doesn't register the Dock tile without it.

## Consequences

- App is now LaunchServices-registered as ApplicationType=Foreground when windowed player is visible
- Dock icon and app-switcher entry appear and disappear dynamically with windowed mode
- Build script no longer hardcodes LSUIElement — runtime controls it
- Policy check guards against redundant calls and ensures window visibility check is current

## Open Tail

*(none)*

## Evidence

- transcript lines 1303-1304
- transcript lines 1395-1473
- transcript lines 1553-1607
- transcript lines 2042-2044

## Conversation

- Cleaned transcript (verbatim user words, abbreviated agent replies): [`transcripts/2026-07-14-b9fc703882a9-e3224aba-2-static-lsuielement-true-in-info-plist.json`](transcripts/2026-07-14-b9fc703882a9-e3224aba-2-static-lsuielement-true-in-info-plist.json)
- Raw transcript (verbatim user words, full agent replies): [`transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-2-static-lsuielement-true-in-info-plist.json`](transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-2-static-lsuielement-true-in-info-plist.json)

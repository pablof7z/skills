---
type: episode-card
date: 2026-07-14
session: b9fc7038-82a9-471c-b5bc-438fc1890d3c
transcript: /Users/pablofernandez/.claude/projects/-Users-pablofernandez-Work-skills--claude-worktrees-tts-windowed-mode/b9fc7038-82a9-471c-b5bc-438fc1890d3c.jsonl
salience: product
status: active
subjects:
  - workspace-accent
  - project-colors
  - fnv-hash
  - palette
supersedes: []
related_claims: []
source_lines:
  - 2231-2247
  - 2307-2310
  - 2345-2346
  - 2518-2518
captured_at: 2026-07-14T11:18:03Z
---

# Episode: Project accent colors replaced with 29er-next's FNV-1a continuous hue algorithm

## Prior State

WorkspaceAccent used a fixed discrete palette of 8 hardcoded Color values, indexed by paletteIndex derived from the project label hash.

## Trigger

Decision to match 29er-next's deterministic project color approach for visual consistency across apps.

## Decision

Replaced the 8-color discrete palette with 29er-next's continuous hue-based algorithm: FNV-1a 64-bit hash of the project label → continuous HSB hue, with saturation 0.58 and brightness 0.78. Same algorithm, same constants as 29er-next's avatarColor extension.

## Consequences

- Project accent colors are now continuous (infinite distinct hues) rather than limited to 8 fixed colors
- Color assignment is consistent with 29er-next's avatar/group/backend colors
- Old 8-color palette is historical
- Existing test derivesStableAccentFromGitProjectRoot still passes (tests label derivation, not color values)

## Open Tail

*(none)*

## Evidence

- transcript lines 2231-2247
- transcript lines 2307-2310
- transcript lines 2345-2346
- transcript lines 2518-2518

## Conversation

- Cleaned transcript (verbatim user words, abbreviated agent replies): [`transcripts/2026-07-14-b9fc703882a9-e3224aba-5-project-accent-colors-replaced-with-29er.json`](transcripts/2026-07-14-b9fc703882a9-e3224aba-5-project-accent-colors-replaced-with-29er.json)
- Raw transcript (verbatim user words, full agent replies): [`transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-5-project-accent-colors-replaced-with-29er.json`](transcripts/raw/2026-07-14-b9fc703882a9-e3224aba-5-project-accent-colors-replaced-with-29er.json)

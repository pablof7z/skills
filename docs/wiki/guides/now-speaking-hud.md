---
title: Now Speaking HUD
slug: now-speaking-hud
topic: tts-playback
summary: The Now Speaking HUD is a borderless, non-activating NSPanel that never steals keyboard focus
tags:
  - capture
volatility: warm
confidence: medium
created: 2026-07-13
updated: 2026-07-13
verified: 2026-07-13
compiled-from: conversation
sources:
  - session:019f5a1a-8895-7503-abfc-7ae32801d0b5
---

# Now Speaking HUD

## Panel Architecture

The Now Speaking HUD is a borderless, non-activating NSPanel that never steals keyboard focus. It is positioned at the bottom-left of the screen, inside the usable area. Playback start must explicitly order the HUD onscreen, independent of the menu-bar popover. <!-- [^019f5-81a10] -->

## Display Content

The HUD shows the subject as the headline with `agent · workspace` beneath it. Text should be larger than the initial implementation. <!-- [^019f5-69e07] -->

## Controls

The HUD includes controls for pause/resume, stop, and 15-second back/forward skip. The progress bar allows scrubbing to any point in the timeline. <!-- [^019f5-23764] -->

## Mouseover Behavior

On mouseover the HUD animates to a larger size. <!-- [^019f5-2c822] -->

## Appearance & Linger Lifecycle

The HUD appears when speech starts, stays prominent for 4–6 seconds, then collapses to a subtle indicator until playback ends. After playback ends, the completed HUD lingers for about eight seconds, retaining transcript, timeline, and duration. The post-playback countdown pauses when the user hovers the HUD and resumes from the remaining time (not a fresh eight seconds) when the pointer leaves. A newly starting TTS item cancels the linger countdown immediately. On expiry the HUD fades out over a 340ms animation before removal. Starting or restarting playback cancels both the countdown and the fade immediately and restores full opacity. <!-- [^019f5-3b96d] -->

## Transcript Mode

Clicking the HUD opens an in-place transcript mode that uses the same dark/material visual language as the HUD. The transcript renders as natural prose with normal word spacing and tighter line rhythm, not as tag-chip style word blocks. It follows the currently spoken word with live highlighting and makes each word a seek target. Transcript words have a hover effect—pointer cursor, subtle accent-backed hover state, and a tiny scale/luminance lift—to make click-to-seek discoverable. During the post-playback grace period, clicking a word or scrubbing the timeline enqueues a replay from the selected approximate offset. <!-- [^019f5-0c68c] -->

## Accent Color

The HUD uses a deterministic accent color derived from the workspace directory name as a stable seed into a curated color palette, so the same project consistently gets the same accent. <!-- [^019f5-a0c13] -->

## Project Identity

Project identity for the HUD is derived from the nearest Git worktree root name, not the current folder's basename. Outside Git, the project identity falls back to the cwd basename. The display rule is: inside Git show only the Git repository root name; outside Git show the recorded directory path. <!-- [^019f5-e0af8] -->

## Performance

The idle CPU regression is caused by every 250ms playback refresh assigning `lingeringItem = nil` even when already nil, publishing a presentation change that triggers overlapping no-op animations. Presentation state updates are idempotent: unchanged presentation publishes are suppressed and identical frame/opacity animations are skipped. The transcript word tree is rebuilt only when the active word actually changes, not on every 250ms playback tick. Auto-scroll runs in stable chunks instead of on every word change. <!-- [^019f5-30578] -->

## Agent Session Jump

Jumping to the speaking agent's iTerm tab is feasible by capturing a terminal locator (iTerm session ID, Tenex PTY, Codex thread) with every TTS queue item and showing an 'Open agent session' button only when one exists. The session-jump feature requires macOS Automation permission for the TTS app to control iTerm. <!-- [^019f5-6ea86] -->

## Audible TTS Invocations

Audible TTS invocations print "TTS audio will play in the background after generation completes," while `--no-play` stays quiet. <!-- [^019f5-dd79e] -->

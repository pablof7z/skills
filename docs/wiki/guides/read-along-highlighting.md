---
title: Read-Along Highlighting
slug: read-along-highlighting
topic: tts-playback
summary: The Kokoro service exposes `/dev/captioned_speech`, which returns real per-word `start_time`/`end_time` values including punctuation tokens
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

# Read-Along Highlighting

## Timing Source

The Kokoro service exposes `/dev/captioned_speech`, which returns real per-word `start_time`/`end_time` values including punctuation tokens. These timestamps are the source of truth for all read-along highlighting. <!-- [^019f5-e4cce] -->

## Two-Layer Highlighting

Read-along highlighting uses a two-layer system: a softly highlighted phrase or clause provides stable context, while the precisely timed current word appears as a stronger playhead inside that phrase. The current-word emphasis does not change the layout box, so the prose layout remains completely stable during highlighting. <!-- [^019f5-9f729] -->

## Phrase Formation

Phrases are formed from punctuation, linguistic boundaries, and measured pauses—not fixed word counts. <!-- [^019f5-f8095] -->

## Active Phrase Treatment

The active phrase receives a calm project-colored treatment. <!-- [^019f5-a2f8d] -->

## Scrolling Behavior

Scrolling occurs only when the active phrase approaches a viewport boundary, not on every word change. <!-- [^019f5-57a7c] -->

## Interaction

Word-tap seeking uses real TTS timestamps. Previous and next controls operate on phrases or sentences. <!-- [^019f5-26dd4] -->

## Highlighting Modes

Highlighting preferences will eventually expose Phrase + Word, Word, Sentence, and Off modes. <!-- [^019f5-1f366] -->

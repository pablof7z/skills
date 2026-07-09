---
name: tts
description: Generate speech from text with a Kokoro endpoint.
---

# TTS Skill

Generate spoken audio from text with a Kokoro-compatible endpoint.

## Input text rules

Use natural sentences for best results.

- **Acronyms**: Write as you'd type them — `CLI`, `API`, `HTTP`, etc. The skill auto-converts to `C L I`, `A P I`, `H T T P` for letter-by-letter pronunciation.
- **Abbreviations**: Expand when pronunciation matters — `AI` → `artificial intelligence`, `DB` → `database`, `API` → `application programming interface`.
- **Code & paths**: Avoid or rephrase — instead of `run /usr/local/bin/script`, say `run the script`.
- **Punctuation**: Natural pauses work; avoid excessive symbols.

## Available voices

American English deterministic pool: `af_bella`, `af_heart`, `af_kore`, `af_nova`, `af_sarah`, `am_michael`, `am_puck`

Other languages & accents available: British English, Japanese, Mandarin, French, Italian, Portuguese.

## Agent identity

Always pass `--introduction` with a brief spoken preamble of 30 words or fewer:

```text
Agent <name> here, working on <short user-meaningful task>.
```

Use a phrase the listener can understand without opening a tracker, such as
`improving TTS identity cues` or `refactoring the lib module`, not bare tracker
labels or numeric references.

The script decides whether to prepend it. If the same agent spoke within ten
minutes, the intro is skipped; if another agent spoke since then, or enough time
passed, the intro is included again.

Pass `--agent-name` only when the session has a specific identifier beyond the
harness name. Use names like `quinn-delta-306`; do not use generic values like
`codex` or `claude`. When using `--agent-name`, omit voice selection so the
script can choose a deterministic voice from that name. Use `--voice-id` only
when a specific voice is required.

## Playback behavior

On macOS, `scripts/tts` checks scriptable media apps before generation and again before playback. If Music or Spotify is already playing, it pauses them and resumes them a few seconds after playback ends.

- Use `--no-play` to generate the MP3 without playing it.
- Use `--voice-id voice` to choose an explicit voice.
- Use `--no-media-pause` or `TTS_MEDIA_CONTROL=0` to skip media pausing.
- Use `--resume-delay seconds` or `TTS_RESUME_DELAY_SECONDS=seconds` to change the resume delay.
- Use `TTS_MEDIA_APPS="Music,Spotify"` to customize the checked apps.

By default, `scripts/tts` generates an MP3 and plays it automatically with the local audio player when available.

`./scripts/tts --agent-name quinn-delta-306 --introduction "Agent Quinn here, working on improving TTS identity cues." "The fix is ready."` will speak with identity context when needed.

`./scripts/tts --no-play --voice-id af_bella "Hello world"` will skip playback and use an explicit voice.

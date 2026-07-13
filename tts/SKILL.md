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

## Subject

Use `--subject` when a substantive update benefits from a scannable topic in
the queue. Write 5 to 10 words that name the outcome or subject clearly. The
subject is displayed prominently in the player and spoken immediately after
any introduction, before the message body.

Skip `--subject` when it would add ceremony without useful context, such as a
brief conversational response, acknowledgement, or follow-up question.

## Playback behavior

By default, `scripts/tts` generates the MP3 in the foreground, then queues
playback in the background so the agent sees endpoint/setup failures before the
command returns.

On macOS, the first audible request starts a resident menu-bar app. It owns the
playback queue, shows queued/current/recent speech, and provides pause, resume,
15-second skip controls, and replay by clicking a recent row. The current item
uses a podcast-style player with a stable read-along transcript. When the
endpoint supports captioned speech, a softly focused phrase preserves context
while an exact word playhead follows synthesis timestamps; clicking a word
seeks to its real audio boundary.
While an item is playing or paused, the popup focuses on its full player and
transcript; the queue and recent history return when playback becomes idle.
Queue rows include the text, voice, agent name, and any harness, full session
identifier, subject, and workspace metadata available in the calling
environment.

Use `scripts/tts-menu status` to check whether TTS is playing and inspect queue
counts. Use `scripts/tts-menu status --json` for structured status. Use
`scripts/tts-menu start`, `stop`, or `restart` to manage the menu-bar process.

If the native app is disabled or cannot start, background playback workers use
the speech gate so only one audible TTS job speaks at a time. Set
`TTS_MACOS_MENU=0` to force this fallback.

On macOS, the script checks scriptable media apps before generation and the
active playback backend checks again before playback. If Music or Spotify is
already playing, it pauses them and resumes them a few seconds after playback
ends.

- Use `--no-play` to generate the MP3 without playback and print its path only after the file exists.
- Use `--voice-id voice` to choose an explicit voice.
- Use `--no-media-pause` or `TTS_MEDIA_CONTROL=0` to skip media pausing.
- Use `--resume-delay seconds` or `TTS_RESUME_DELAY_SECONDS=seconds` to change the resume delay.
- Use `TTS_MEDIA_APPS="Music,Spotify"` to customize the checked apps.

Queue records, process state, and logs live under the TTS state directory,
normally `~/.local/state/tts/`.

`./scripts/tts --agent-name quinn-delta-306 --introduction "Agent Quinn here, working on TTS." --subject "Playback queue ownership is now explicit" "The fix is ready."` will speak the introduction when needed, then the subject, then the body.

`./scripts/tts --no-play --voice-id af_bella "Hello world"` will generate the MP3, print its output path, skip playback, and use an explicit voice.

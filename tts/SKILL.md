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

## Attachments

Use repeatable `--attach "Label" path` arguments when a concise spoken update
has genuinely useful supporting material. Prefer short, human labels such as
`Why this matters`, `Screenshot`, or `Detailed findings`; never expose a raw
filename as the label when a clearer description is available.

Pass the primary body with `--message` when attachments are present:

```bash
./scripts/tts \
  --message "The implementation is ready. I attached the rationale and a screenshot." \
  --attach "Why this matters" ./why-this-matters.md \
  --attach "Screenshot" ./screenshot.png
```

Markdown and text attachments are copied into durable session storage, shown
with their structure preserved, and narrated in the background using the same
voice as the primary update. Images preview inline, existing audio is playable,
and other files can be opened in their default app. Attachments are optional
branches: they do not count as queued speech until the user selects them. Do
not attach routine logs, duplicate the primary message, or create supplemental
files only to make an update look more substantial.

## Playback behavior

By default, `scripts/tts` generates the MP3 in the foreground, then queues
playback in the background so the agent sees endpoint/setup failures before the
command returns.

On macOS, the first audible request starts a resident menu-bar app. It owns the
playback queue and shows queued/current/recent speech. Playback lives in the
floating bottom-left player, which provides pause, resume, 15-second skip
controls, a per-voice speed control, and a stable read-along transcript. The
expanded HUD always shows the transcript without a separate toggle. When the
endpoint supports captioned speech, a softly focused phrase preserves context
while an exact word playhead follows synthesis timestamps; clicking a word
seeks to its real audio boundary. The transcript shows only the agent's message,
not the spoken introduction or subject, and preserves paragraphs, lists,
headings, emphasis, links, and code-oriented Markdown styling.
Clicking the speed label cycles through `0.75×`, `1×`, `1.25×`, `1.5×`, and
`2×`; the selected rate applies immediately and is remembered for that voice.
The menu-bar popup remains a queue overview while speech is active: it lists
the current item, upcoming items, and recent history without duplicating the
player or transcript. Its Pause All toggle keeps current and newly generated
speech waiting until resumed, and the menu-bar badge shows the queued count.
The player can be dragged from any non-interactive background and its expanded
view has forgiving resize zones on every edge and corner, with the original `540×470` layout
as its minimum unless the display itself is smaller. A remembered header control
switches manually between expanded and mini-player modes; hover never changes
the window size. Position, expanded size, mini-player mode, and
Show Player / Hide Player state are remembered; the header × hides the HUD
without stopping speech. Display changes clamp the whole frame onto a remaining
visible screen and reduce an oversized saved frame to fit. Right-clicking the
TTS status item also exposes Show/Hide Player and Pause/Resume All; left-click
still opens the queue popup.
After generation, the command reports the current queue count. If global TTS
playback is paused, it explicitly says that the audio was generated and queued
but will not play until resumed; relay that state accurately rather than
claiming the user heard it.
Muted macOS system output also pauses playback automatically. Generation reports
that muted state so the agent knows the speech was not audible. Playback resumes
after unmute only when mute itself caused the pause; a user-paused item stays
paused.
Queue rows include the text, voice, agent name, and any harness, full session
identifier, subject, and workspace metadata available in the calling
environment. In linked Git worktrees, the base repository is the primary
project label and a differing checkout name appears as secondary context; the
accent color remains stable across all worktrees of that project.

The generated message MP3, timing data, copied attachment sources, and prepared
attachment narration live together under
`~/.agents/skills/tts/sessions/<session-id>/briefs/<item-id>/`. Set
`TTS_SESSIONS_ROOT` only when an alternate durable root is required. Source
worktrees may disappear after the command returns; always rely on the copied
brief assets rather than the original attachment path.

Use `scripts/tts-menu status` to check whether TTS is playing and inspect queue
counts. Use `scripts/tts-menu status --json` for structured status. Use
`scripts/tts-menu start`, `stop`, or `restart` to manage the menu-bar process.

If the native app is disabled or cannot start, background playback workers use
the speech gate so only one audible TTS job speaks at a time. Set
`TTS_MACOS_MENU=0` to force this fallback.

On macOS, media keeps playing while audio is generated. Once the MP3 has fully
arrived, the playback backend checks Music and Spotify. If it actually pauses
one of them, it leaves a two-second handoff before speech begins, then resumes
the paused apps a few seconds after playback ends.

- Use `--no-play` to generate the MP3 without playback and print its path only after the file exists.
- Use `--message text` for an explicit primary message; the original positional message remains supported.
- Use repeatable `--attach "Label" path` pairs to add durable supporting material.
- Use `--voice-id voice` to choose an explicit voice.
- Use `--no-media-pause` or `TTS_MEDIA_CONTROL=0` to skip media pausing.
- Use `--handoff-delay seconds` or `TTS_MEDIA_HANDOFF_DELAY_SECONDS=seconds` to change the post-pause handoff.
- Use `--resume-delay seconds` or `TTS_RESUME_DELAY_SECONDS=seconds` to change the resume delay.
- Use `TTS_MEDIA_APPS="Music,Spotify"` to customize the checked apps.

Queue records, process state, and logs live under the TTS state directory,
normally `~/.local/state/tts/`.

`./scripts/tts --agent-name quinn-delta-306 --introduction "Agent Quinn here, working on TTS." --subject "Playback queue ownership is now explicit" "The fix is ready."` will speak the introduction when needed, then the subject, then the body.

`./scripts/tts --no-play --voice-id af_bella "Hello world"` will generate the MP3, print its output path, skip playback, and use an explicit voice.

---
name: tts
description: Generate speech from text with a Kokoro endpoint.
---

# TTS Skill

Generate spoken audio from text with a Kokoro-compatible endpoint.

## Input text rules

Use natural sentences for best results.

- **Acronyms**: Write them as you naturally would — `JSON`, `CLI`, `API`. Some read
  better as words (`JSON`), others letter-by-letter (`CLI`). Expand only when the
  spoken form would be unclear to a listener.
- **Abbreviations**: Expand when pronunciation matters — `AI` → `artificial
  intelligence`, `DB` → `database`, `API` → `application programming interface`.
- **Code & paths**: Avoid or rephrase — instead of `run /usr/local/bin/script`, say
  `run the script`. See *Code blocks* below for inline code in messages.
- **Punctuation**: Natural pauses work; avoid excessive symbols.

## Voice

A voice is assigned deterministically from your agent identity — you don't choose
one.

## Agent identity

Pass `--agent-name` only when the session has a specific identifier beyond the
harness name. Use names like `<your-agent-id>`; do not use generic values like
`codex` or `claude`.

Agent attribution comes from this metadata and the calling harness. Do not
repeat the agent name or identity in the spoken message.

## Subject

Use `--subject` as a stable topic — like a session title that reflects what is
being done. Keep it consistent across calls within the same work session. If you
know your session's title, use it verbatim. Write 5 to 10 words.

Skip `--subject` when it would add ceremony without useful context, such as a
brief conversational response, acknowledgement, or follow-up question.

## Attachments

Use repeatable `--attach "Label" path` arguments when a concise spoken update
has genuinely useful supporting material. Prefer short, human labels such as
`Mockup A`, `Architectural proposal`, or `Detailed findings`; never expose a raw
filename as the label when a clearer description is available.

SVG and Mermaid (`.mmd`) diagrams are supported alongside PNG, JPEG, and other
image formats — use them when a visual communicates more than text.

Pass the primary body with `--message` when attachments are present:

```bash
./scripts/tts \
  --agent-name "<your-agent-id>" \
  --message "The implementation is ready. I attached the proposal and a mockup." \
  --attach "Architectural proposal" ./proposal.md \
  --attach "Mockup A" ./mockup-a.svg
```

Markdown and text attachments are copied into durable session storage, shown
with their structure preserved, and narrated using the same voice as the primary
update before the command returns. Images and SVGs preview inline, Mermaid attachments
render as diagrams with a readable source fallback, existing audio is playable,
and other files can be opened in their default app. Attachments are optional
branches: narrated text and audio do not count as queued speech until the user
selects them, while images and diagrams are preview-only. Do not attach routine
logs, duplicate the primary message, or create supplemental files only to make
an update look more substantial.

## Code blocks

When a message includes code, use fenced code blocks with a language tag for
syntax-highlighted rendering:

````
Ok, here's a brief proposal for how that API would look:

```ts
const event = new NDKEvent();
event.content = 'blah';
await event.sign();
```
["The code shows a simple NDKEvent construction, but the key aspect is that we can sign it without broadcasting to get the signature with a simple awaited event dot sign call."]
````

Rules:

- ` ```lang ` blocks (with a language like `ts`, `swift`, `rs`, `py`) are
  rendered with syntax highlighting in the transcript and **skipped** in speech.
  Follow the block with a `["…"]` spoken description in brackets — that
  description is speech-only and is not shown in the transcript. While it is
  spoken, the tagged code and visible transcript remain unhighlighted;
  read-along highlighting resumes with the next visible spoken word.
- ` ``` ` blocks (no language tag) are read aloud as plain text and rendered as
  plain monospace code. Use this for short snippets, paths, or commands where
  hearing the literal text is the point.

## Playback behavior

By default, `scripts/tts` generates the primary MP3 and any narrated attachments
in the foreground, then queues playback in the background. Command completion is
the reliable boundary for observing endpoint, setup, and attachment-generation
failures.

If the execution environment can run a command asynchronously, start the whole
`scripts/tts` command with that capability when waiting would block unrelated
work. Keep its execution handle and wait for completion before claiming that the
spoken update was generated. Use the execution environment's process controls;
do not add shell-specific process-management examples to the skill.

## Questions and answers

Use `--ask` when the spoken message is a question that should remain available
for an answer. The command waits until the user answers or an agent supersedes
the question, and its JSON output includes the answer. Run the command
with the execution environment's asynchronous process capability when other work
should continue while the question is pending.

Offer optional answer ideas with `--suggestions` as a JSON array of title and
description pairs:

```bash
./scripts/tts --ask \
  --suggestions '[["Use the existing model", "Keep the current ownership boundary."], ["Split the model", "Give questions an independent lifecycle."]]' \
  --message "Which direction should I take?"
```

Suggestions are editable starting points. The player always includes a freeform
input, so never add a `Something else`, `Other`, or equivalent suggestion.
`--ask` is incompatible with `--no-play`.

Every invocation prints a machine-readable result containing its stable `id`;
diagnostics go to standard error. Use that ID to inspect delivery and engagement
evidence. Treat engagement as evidence, not proof: automatic playback without
activity can be unattended, general activity confirms presence only, and direct
player interaction is the strongest listening signal short of an answer.

Inspect the shared queue with bounded pages (20 items by default, 100 maximum):

```bash
./scripts/tts-menu queue list
./scripts/tts-menu queue list --offset 20 --limit 20
./scripts/tts-menu queue list --mine
./scripts/tts-menu queue get <id>
./scripts/tts-menu queue wait <id>
```

The list output includes `pagination.next_offset`; use it to navigate rather
than requesting the entire queue. The default view includes active items from
all agents. Use `--archived` for archived items or `--all` for both.

Archive only to hide an item; it does not cancel a pending answer. Restore with
`queue restore`. When a new question replaces pending questions, supersede them
atomically with a reason and one or more replacement IDs:

```bash
./scripts/tts-menu queue archive <id> --reason "No longer relevant."
./scripts/tts-menu queue restore <id>
./scripts/tts-menu queue supersede <id1> <id2> \
  --superseded-by <id3> \
  --reason "The questions overlapped and the replacement includes the missing nuance."
```

Only pending questions may be superseded. An answer and a supersession race are
resolved atomically; the first terminal operation wins.

On macOS, the first audible request starts a resident menu-bar app. It owns the
playback queue and shows queued/current/recent speech. Playback lives in the
floating bottom-left player, which provides pause, resume, 15-second skip
controls, a per-voice speed control, and a stable read-along transcript. The
expanded HUD always shows the transcript without a separate toggle. When the
endpoint supports captioned speech, a softly focused phrase preserves context
while an exact word playhead follows synthesis timestamps; clicking a word
seeks to its real audio boundary. The transcript shows only the visible content
of the agent's message, excluding the spoken subject and
speech-only code descriptions. It preserves paragraphs, lists, headings,
emphasis, links, and code-oriented Markdown styling.
Clicking the speed label cycles through `0.75×`, `1×`, `1.25×`, `1.5×`, and
`2×`; the selected rate applies immediately and is remembered for that voice.
The menu-bar popup remains a queue overview while speech is active: it lists
the current item, upcoming items, and recent history without duplicating the
player or transcript. Its Pause All toggle keeps current and newly generated
speech waiting until resumed, and the menu-bar badge shows the queued count.
The windowed player's idle history keeps replayed items at their original
generation time, shows relative times during the first 24 hours and absolute
timestamps afterward, and keeps search beside the project filter in the native
titlebar toolbar. That filter menu selects recent or archived history, while
swiping left archives an update and the archived view offers restore.
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
When an audible macOS request begins, the windowed player immediately shows the
new update with a progress indicator. Its durable text can be opened and read
while audio is generated; that preview becomes the normal player when audio
starts. This generating row does not enter the playable queue or inflate its
badge. The same row becomes queued when audio is ready, or failed if synthesis
exits unsuccessfully.
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
When the speaking item came from a currently reachable iTerm session, the
player header offers an Open agent session control that selects the exact tab or
split and activates iTerm. The control stays absent when no supported terminal
locator was captured and disappears if the original session ends.

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

- Use `--no-play` to generate the MP3 without playback. Its JSON result includes the path only after the file exists.
- Use `--message text` for an explicit primary message; the original positional message remains supported.
- Use repeatable `--attach "Label" path` pairs to add durable supporting material.
- Use `--no-media-pause` or `TTS_MEDIA_CONTROL=0` to skip media pausing.
- Use `--handoff-delay seconds` or `TTS_MEDIA_HANDOFF_DELAY_SECONDS=seconds` to change the post-pause handoff.
- Use `--resume-delay seconds` or `TTS_RESUME_DELAY_SECONDS=seconds` to change the resume delay.
- Use `TTS_MEDIA_APPS="Music,Spotify"` to customize the checked apps.

Queue records, process state, and logs live under the TTS state directory,
normally `~/.local/state/tts/`.

`./scripts/tts --agent-name "<your-agent-id>" --subject "<stable session topic>" "<message>"` will speak the subject, then the body.

`./scripts/tts --no-play "<message>"` generates the MP3, returns its stable ID and output path as JSON, and skips playback.

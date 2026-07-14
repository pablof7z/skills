# TTS

## Hear what your agents are doing without watching every terminal

Agent work is increasingly parallel, but attention is still serial. Important updates arrive in panes, logs, notifications, and chat threads that all expect you to be looking at them.

`tts` gives those updates a shared audio surface. Each agent can finish a meaningful unit of work with a short spoken message, then return control immediately. The listener gets one orderly stream instead of overlapping voices or another queue of unread text.

<p align="center">
  <img src="../assets/tts-menu-player.png" alt="The TTS macOS floating player showing a subject, transcript progress, agent identity, session metadata, timeline, and playback controls" width="460">
</p>

## The experience

The workflow owns more than text generation:

- The HTTP request stays in the foreground until the endpoint accepts it and the audio file exists, so setup and generation failures remain visible to the agent.
- Audible macOS requests appear in the windowed player as soon as synthesis starts. The pending row is dimmed, disabled, and marked with a progress indicator until the same item becomes playable; failures become disabled failed entries instead of getting stuck as pending.
- Successful audio moves into background playback only after that handshake.
- Every update is retained as a durable brief under `~/.agents/skills/tts/sessions/<session-id>/briefs/<item-id>/`, including its MP3, timing data, and any copied attachments.
- One resident macOS process serializes updates from every agent session.
- A floating player identifies the subject, agent, Git project (or directory path outside Git), and progress without taking focus from the current window. Linked worktrees keep the base repository as the primary project and add the differing checkout name as secondary context. When an update came from a live iTerm session, a header control selects that exact tab or split and brings iTerm forward; the control is absent for missing, unsupported, or ended sessions. Its expanded state always places a natural-reading transcript directly beneath the context header, with the scrubber and playback controls anchored below it and no separate transcript toggle. A remembered header control switches manually between expanded and mini-player modes; hover never changes the window size. It uses a stable Git-project accent color for recognition and lingers briefly after speech so missed words can be replayed in place. Hover pauses only that grace period; unused players fade away.
- Dragging any non-interactive player background moves the HUD without stealing focus; transcript words and playback controls keep their clicks. The expanded player has forgiving resize zones on every edge and corner, matching cursors, and a visible corner affordance. It remembers position, expanded size, and manual mini-player mode, and never shrinks below the original 540×470 layout unless the remaining display itself is smaller. Its header × hides it immediately, while the menu popup remembers Show Player / Hide Player without stopping speech. Disconnecting or rearranging displays clamps the whole saved frame inside a visible screen and reduces an oversized frame to fit.
- The transcript shows only the agent's message while the introduction and subject remain audible. It preserves paragraphs and lists, renders common Markdown structure, keeps a natural phrase softly in focus, and follows real synthesis timestamps with a stronger word playhead. Its prose geometry stays fixed, phrase following scrolls only when needed, and every mapped word seeks to its actual audio boundary.
- A brief can carry labeled attachments. The expanded player presents them in a compact accent-tinted rail: Markdown and text become optional narrated branches with readable previews, images open inline in the transcript surface, existing audio plays in context, and other files open in their default app. Supplemental narration returns to the main update at the saved position and never enters the ordinary queue until selected.
- Agent name, voice, harness, workspace, and full session identifier make each update attributable.
- An optional 5-to-10-word subject is spoken after the introduction and gives substantive updates a scannable title in the player and queue.
- Pause, timeline scrubbing, 15-second seek, and replay make it behave like a small podcast queue rather than a fire-and-forget alert.
- A compact speed label on the floating player cycles through common playback rates and remembers the selected rate independently for each voice.
- The menu-bar popup stays focused on queue operations—now playing, up next, and recent items—without duplicating the player or transcript.
- The menu-bar popup can pause or resume all TTS playback without discarding queued audio. Its menu-bar badge shows how many items are waiting, and each generation reports the queue count plus a clear warning when global playback is paused.
- Right-clicking the TTS status item exposes Show/Hide Player and Pause/Resume All as a compact native quick menu; left-click still opens the queue popup.
- Muted macOS system output automatically pauses TTS without losing its position. Playback resumes after unmute only when mute caused the pause, and the generator tells the agent that the queued speech was not audible.
- Music and Spotify keep playing during generation. After the MP3 arrives, active media can be paused; when something was actually paused, a short handoff keeps speech from starting on top of the transition. Paused media resumes afterward.

The result is ambient awareness with provenance: you can hear that something changed, know which agent changed it, and revisit the exact words later.

## First spoken update

Configure a Kokoro-compatible endpoint, then run:

```bash
export KOKORO_API_ENDPOINT="https://<your-host>/v1/audio/speech"
./scripts/tts \
  --agent-name "<your-agent-id>" \
  --introduction "Agent <name> here, working on the repository launch." \
  --subject "The repository launch update is ready" \
  --message "The README update is ready for review. I attached the proposal and a mockup." \
  --attach "Architectural proposal" ./proposal.md \
  --attach "Mockup A" ./mockup-a.svg
```

On macOS 13 or later with Swift available, the first audible request builds and starts the menu-bar player. The command returns after generation succeeds and the item has been accepted for playback.

Use `./scripts/tts-menu status` to inspect current playback and queue counts. Use `--no-play` when you only need the generated file; that command returns only after the file exists.

## What it touches

`tts` sends the supplied message and narratable text attachments to the endpoint you configure. It copies attachment sources and writes generated audio under `~/.agents/skills/tts/sessions`, keeps queue state under `~/.local/state/tts`, and may pause or resume supported media apps on macOS. Set `TTS_SESSIONS_ROOT` to override the durable brief location and `TTS_MEDIA_CONTROL=0` to disable media control.

See [setup](references/setup.md) for endpoint configuration and [SKILL.md](SKILL.md) for the exact agent-facing writing and invocation rules.

# TTS

## Hear what your agents are doing without watching every terminal

Agent work is increasingly parallel, but attention is still serial. Important updates arrive in panes, logs, notifications, and chat threads that all expect you to be looking at them.

`tts` gives those updates a shared audio surface. Each agent can finish a meaningful unit of work with a short spoken message, then return control immediately. The listener gets one orderly stream instead of overlapping voices or another queue of unread text.

<p align="center">
  <img src="../assets/tts-menu-player.png" alt="The TTS macOS menu-bar player showing a subject, transcript progress, agent identity, session metadata, timeline, and playback controls" width="460">
</p>

## The experience

The workflow owns more than text generation:

- The HTTP request stays in the foreground until the endpoint accepts it and the audio file exists, so setup and generation failures remain visible to the agent.
- Successful audio moves into background playback only after that handshake.
- One resident macOS process serializes updates from every agent session.
- A passive bottom-left cue identifies the subject, agent, workspace, and progress without taking focus from the current window.
- The current transcript receives the full player surface, with approximate word highlighting as playback advances.
- Agent name, voice, harness, workspace, and full session identifier make each update attributable.
- An optional 5-to-10-word subject is spoken after the introduction and gives substantive updates a scannable title in the player and queue.
- Pause, timeline scrubbing, 15-second seek, and replay make it behave like a small podcast queue rather than a fire-and-forget alert.
- Music and Spotify can be paused for speech and resumed afterward.

The result is ambient awareness with provenance: you can hear that something changed, know which agent changed it, and revisit the exact words later.

## First spoken update

Configure a Kokoro-compatible endpoint, then run:

```bash
export KOKORO_API_ENDPOINT="https://<your-host>/v1/audio/speech"
./scripts/tts \
  --agent-name nova-summit-482 \
  --introduction "Agent Nova here, working on the repository launch." \
  --subject "The repository launch update is ready" \
  "The README update is ready for review."
```

On macOS 13 or later with Swift available, the first audible request builds and starts the menu-bar player. The command returns after generation succeeds and the item has been accepted for playback.

Use `./scripts/tts-menu status` to inspect current playback and queue counts. Use `--no-play` when you only need the generated file; that command returns only after the file exists.

## What it touches

`tts` sends the supplied text to the endpoint you configure. It writes generated audio under `/tmp`, keeps queue state under `~/.local/state/tts`, and may pause or resume supported media apps on macOS. Set `TTS_MEDIA_CONTROL=0` to disable media control.

See [setup](references/setup.md) for endpoint configuration and [SKILL.md](SKILL.md) for the exact agent-facing writing and invocation rules.

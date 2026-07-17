# Results And Troubleshooting

Read this reference only when the task requires no-play generation, delivery or
queue inspection, or failure diagnosis.

## Generate without playback

Use `--no-play` to generate an MP3 without queueing playback:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<seed-name>" \
  --subject "Standalone Audio" \
  --summary "The requested audio is being generated without player playback." \
  --no-play \
  --message "<spoken content>"
```

The command returns only after the file exists. Its tool output includes the
stable item ID and output path. With a configured local Kokoro endpoint, it
generates on the invoking computer and neither sends a paired Nostr request nor
queues player playback. `--no-play` cannot be combined with `--ask`.

## Inspect status when needed

```bash
<skill-dir>/scripts/tts-menu status
<skill-dir>/scripts/tts-menu status --json
<skill-dir>/scripts/tts-menu queue list --mine
<skill-dir>/scripts/tts-menu queue get <id>
<skill-dir>/scripts/tts-menu queue wait <id> --timeout 5m
```

Treat engagement as evidence, not proof that the user heard an update.
Automatic playback without activity can be unattended; general activity shows
presence; direct player interaction is the strongest listening signal short of
an answer.

If command output reports paused playback or muted system audio, relay that
state accurately rather than claiming the update was heard.

## Diagnose failures

- Endpoint or authentication failure: if no approved paired laptop is
  available, read [setup.md](setup.md) and verify the configured Kokoro
  endpoint.
- Generation failure: use the command's standard-error diagnostics.
- Queue or playback failure: inspect `tts-menu status` and the item by ID.
- State inspection: queue records and logs normally live under
  `~/.local/state/tts/`.
- Durable brief inspection: generated audio, timings, and copied attachments
  live under `~/.agents/skills/tts/sessions/<session-id>/briefs/<item-id>/`.

# TTS producer adapter

This installable skill lets an agent publish a spoken update or bounded question
through a separately installed [TTS29](https://github.com/pablof7z-agent/tts29)
daemon.

The skill no longer bundles a player, synthesizer, paired-device transport,
queue, or MCP server. The standalone product generates and publishes one
durable NIP-29 item; iPhone, macOS, and other compatible clients reconstruct and
play it independently.

```bash
export TTS29_SOCKET="$HOME/.local/state/tts29/daemon.sock"
export TTS29_GROUP_ID="tts"

./scripts/tts \
  --agent-name "codex" \
  --subject "Build Ready" \
  --summary "The verified build is ready for review." \
  --message "The build passed its release checks and is ready for review."
```

Install and operate `tts29d` and the `tts29` CLI from the standalone repository.
The adapter returns the daemon's durable request, receipt, event, and optional
answer evidence without claiming playback.

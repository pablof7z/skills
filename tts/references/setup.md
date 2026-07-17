# TTS Setup

Set up your own hosted Kokoro FastAPI instance (for example, a CPU-friendly self-hosted endpoint) and point the script to it.

## Required

For local synthesis, set this environment variable before running
`<skill-dir>/scripts/tts`:

- `KOKORO_API_ENDPOINT="https://<your-host>/v1/audio/speech"`

It is not required on a host with an approved paired laptop. Ordinary speech
uses that laptop automatically when no local endpoint is configured.
`--no-play` is intentionally different: it requires a local endpoint and never
uses a paired laptop, because it creates an MP3 without any player side effect.

## Optional

- `KOKORO_API_KEY` for bearer-token auth
- `KOKORO_CAPTIONED_API_ENDPOINT` to override the inferred
  `https://<your-host>/dev/captioned_speech` endpoint used for precise transcript timing
- `TTS_MAX_PARALLEL_GENERATIONS` to override the player Settings value for the
  current process; the shared setting defaults to `2`
- `TTS_GENERATION_TIMEOUT_SECONDS` to override the 60-second end-to-end
  deadline for waiting and synthesis
- `TTS_GENERATION_CONNECT_TIMEOUT_SECONDS` to override the 10-second endpoint
  connection timeout
- Swift from Xcode or the Command Line Tools for the macOS app
- `uv` for the MCP wrapper; its locked project installs the stable MCP Python
  SDK below version 2
- `nak` for real Nostr signing and paired transport, including the short-lived
  Blossom authorization event used by `tts_generate`

## MCP and Blossom

The MCP wrapper defaults to `https://blossom.primal.net` for generation-only
MP3 uploads. Optional overrides are:

- `TTS_BLOSSOM_SERVER` for another HTTPS Blossom origin
- `TTS_BLOSSOM_TIMEOUT_SECONDS` for the upload timeout
- `TTS_BLOSSOM_MAX_BYTES` for the maximum generated MP3 size
- `TTS_BLOSSOM_AUTH_SECONDS` for the short-lived upload authorization window

Public HTTP MCP mode uses pairing-code OAuth when `--public-url` identifies its
external HTTPS origin. Without `--public-url`, local HTTP retains the static
bearer token in `TTS_MCP_TOKEN`. Read [mcp.md](mcp.md) for route, OAuth, ngrok,
and header-monitoring configuration.

## Suggested local env file

The script loads environment variables from `~/.env.tts` by default. You can set:

```bash
KOKORO_API_ENDPOINT=https://<your-host>/v1/audio/speech
KOKORO_API_KEY=<optional bearer token>
```

To use a custom file path, set `KOKORO_ENV_FILE`.

The player Settings window controls the machine-wide generation limit from 1
to 8. All local agents using the same TTS state directory read that setting;
the environment variable above takes precedence when present.

## Notes

The script first requests captioned speech with word timestamps. If that route
is unavailable or returns an invalid response, it warns and falls back to the
standard audio endpoint so speech generation still succeeds; legacy items then
show phrase progress without claiming exact word timing.

Media handoff is disabled by default. Users can opt in from Preferences to let
TTS pause Music and Spotify through their app-specific automation interfaces.
TTS never changes system volume, mute, or audio output routing.

See this guide for a self-hosted Kokoro setup reference:
https://ariya.io/2026/03/local-cpu-friendly-high-quality-tts-text-to-speech-with-kokoro/

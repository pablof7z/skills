# TTS Setup

Set up your own hosted Kokoro FastAPI instance (for example, a CPU-friendly self-hosted endpoint) and point the script to it.

## Required

Set this environment variable before running `<skill-dir>/scripts/tts`:

- `KOKORO_API_ENDPOINT="https://<your-host>/v1/audio/speech"`

## Optional

- `KOKORO_API_KEY` for bearer-token auth
- `KOKORO_CAPTIONED_API_ENDPOINT` to override the inferred
  `https://<your-host>/dev/captioned_speech` endpoint used for precise transcript timing
- Swift from Xcode or the Command Line Tools for the macOS app

## Suggested local env file

The script loads environment variables from `~/.env.tts` by default. You can set:

```bash
KOKORO_API_ENDPOINT=https://<your-host>/v1/audio/speech
KOKORO_API_KEY=<optional bearer token>
```

To use a custom file path, set `KOKORO_ENV_FILE`.

## Notes

The script first requests captioned speech with word timestamps. If that route
is unavailable or returns an invalid response, it warns and falls back to the
standard audio endpoint so speech generation still succeeds; legacy items then
show phrase progress without claiming exact word timing.

The macOS app bundles a small BSD-licensed adapter for Apple's private
MediaRemote framework so it can verify and control the active system Now
Playing session. Because MediaRemote is not a public API, the app falls back to
bundle-identified Music and Spotify AppleScript adapters when it is unavailable.

See this guide for a self-hosted Kokoro setup reference:
https://ariya.io/2026/03/local-cpu-friendly-high-quality-tts-text-to-speech-with-kokoro/

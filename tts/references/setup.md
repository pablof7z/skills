# TTS Setup

Set up your own hosted Kokoro FastAPI instance (for example, a CPU-friendly self-hosted endpoint) and point the script to it.

## Required

Set this environment variable before running `./scripts/tts`:

- `KOKORO_API_ENDPOINT="https://<your-host>/v1/audio/speech"`

## Optional

- `KOKORO_API_KEY` for bearer-token auth
- `KOKORO_DEFAULT_VOICE` to set the default voice (for example, `af_bella`)

## Suggested local env file

The script loads environment variables from `~/.env.tts` by default. You can set:

```bash
KOKORO_API_ENDPOINT=https://<your-host>/v1/audio/speech
KOKORO_API_KEY=<optional bearer token>
KOKORO_DEFAULT_VOICE=af_bella
```

To use a custom file path, set `KOKORO_ENV_FILE`.

## Notes

See this guide for a self-hosted Kokoro setup reference:
https://ariya.io/2026/03/local-cpu-friendly-high-quality-tts-text-to-speech-with-kokoro/

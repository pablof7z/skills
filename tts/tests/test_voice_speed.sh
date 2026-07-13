#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/tts-speed-tests.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

export PATH="$ROOT/tests/fixtures:$PATH"
export KOKORO_ENV_FILE=/dev/null
export KOKORO_API_ENDPOINT=https://mock.invalid/v1/audio/speech
export MOCK_TTS_CAPTURE="$TMP_DIR/payload.json"
export TTS_OUTPUT_FILE="$TMP_DIR/output.mp3"

assert_speed() {
  local expected="$1"
  python3 - "$MOCK_TTS_CAPTURE" "$expected" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected = float(sys.argv[2])
assert payload["speed"] == expected, payload
PY
}

run_generation() {
  rm -f "$MOCK_TTS_CAPTURE" "$TTS_OUTPUT_FILE"
  "$ROOT/scripts/tts" --no-play "$@" >/dev/null
}

TTS_VOICE_SPEEDS="af_bella=0.82,am_michael=1.12" \
  run_generation --voice-id af_bella "Profile speed"
assert_speed 0.82

TTS_VOICE_SPEEDS="af_bella=0.82" \
  run_generation --voice-id af_bella --speed 1.25 "Explicit speed"
assert_speed 1.25

TTS_VOICE_SPEEDS="af_bella=0.82" \
  run_generation --voice-id af_nova "Default speed"
assert_speed 1.0

MOCK_CAPTION_STATUS=404 TTS_VOICE_SPEEDS="af_bella=0.76" \
  run_generation --voice-id af_bella "Fallback speed"
assert_speed 0.76

if TTS_VOICE_SPEEDS="af_bella=" \
  run_generation --voice-id af_bella "Invalid empty profile" 2>"$TMP_DIR/empty-profile.err"; then
  echo "Expected an empty matching voice speed to fail." >&2
  exit 1
fi
rg -q "speed for voice af_bella must be between" "$TMP_DIR/empty-profile.err"
[ ! -e "$MOCK_TTS_CAPTURE" ]

if run_generation --voice-id af_bella --speed 4.1 "Invalid override" 2>"$TMP_DIR/override.err"; then
  echo "Expected an out-of-range speed override to fail." >&2
  exit 1
fi
rg -q "speed for voice af_bella must be between" "$TMP_DIR/override.err"
[ ! -e "$MOCK_TTS_CAPTURE" ]

printf 'voice speed tests passed\n'

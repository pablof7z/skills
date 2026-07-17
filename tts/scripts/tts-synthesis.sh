# shellcheck shell=bash

run_tts_synthesis() {
cleanup() {
  local exit_code=$?
  trap - EXIT
  set +e
  if [ "$exit_code" -ne 0 ]; then
    mark_macos_generation_failed
  fi
  rm -f "$TMP_ERR" "$CAPTION_RESPONSE_FILE"
  release_generation_slot
  release_speech_gate
  exit "$exit_code"
}

trap cleanup EXIT

if [ -n "$PLAY_EXISTING_FILE" ]; then
  play_existing_audio
  exit $?
fi

if [ -z "${KOKORO_API_ENDPOINT:-}" ]; then
  echo "Error: no TTS playback destination is available." >&2
  echo "No local Kokoro endpoint is configured and ordinary routing found no approved paired laptop. Read references/setup.md or references/paired-laptop.md." >&2
  exit 1
fi

if [ "$NO_PLAY" -ne 1 ]; then
  echo "TTS generation runs in the foreground; playback will queue after generation completes." >&2
fi

API_URL="$KOKORO_API_ENDPOINT"
if [[ "$API_URL" != */v1/audio/speech ]]; then
  API_URL="${API_URL%/}/v1/audio/speech"
fi
CAPTIONED_API_URL="${KOKORO_CAPTIONED_API_ENDPOINT:-${API_URL%/v1/audio/speech}/dev/captioned_speech}"

if ! truthy "${TTS_INTERNAL_ATTACHMENT_GENERATION:-0}"; then
  if [ "$NO_PLAY" -ne 1 ] && macos_menu_enabled; then
    begin_macos_generation || begin_durable_generation || true
  else
    begin_durable_generation || true
  fi
fi

if command -v python3 >/dev/null 2>&1; then
  PAYLOAD=$(python3 - "$TEXT" "$VOICE" <<'PY'
import json
import sys
text = sys.argv[1]
voice = sys.argv[2]
print(json.dumps({
    "model": "kokoro",
    "input": text,
    "voice": voice,
    "response_format": "mp3",
    "stream": False,
    "return_timestamps": True,
}))
PY
)
else
  PAYLOAD="{\"model\":\"kokoro\",\"input\":\"$TEXT\",\"voice\":\"$VOICE\",\"response_format\":\"mp3\",\"stream\":false,\"return_timestamps\":true}"
fi

AUTH_OPTS=()

if [ -n "${KOKORO_API_KEY:-}" ]; then
  AUTH_OPTS+=( -H "Authorization: Bearer $KOKORO_API_KEY" )
elif [ -n "${KOKORO_API_USERNAME:-}" ] && [ -n "${KOKORO_API_PASSWORD:-}" ]; then
  AUTH_OPTS+=( -u "$KOKORO_API_USERNAME:$KOKORO_API_PASSWORD" )
fi

acquire_generation_slot

set +e
HTTP_CODE=$(curl -sS -X POST -H "Content-Type: application/json" -d "$PAYLOAD" \
  ${AUTH_OPTS[@]+"${AUTH_OPTS[@]}"} "$CAPTIONED_API_URL" -w "%{http_code}" -o "$CAPTION_RESPONSE_FILE" 2>"$TMP_ERR")
CURL_STATUS=$?
set -e

CAPTIONED_READY=0
if [ "$CURL_STATUS" -eq 0 ] && [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ] && command -v python3 >/dev/null 2>&1; then
  if python3 - "$CAPTION_RESPONSE_FILE" "$OUTPUT_FILE" "$TIMESTAMPS_FILE" 2>"$TMP_ERR" <<'PY'
import base64
import json
import os
import sys
import tempfile

source, audio_destination, timestamp_destination = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    response = json.load(handle)

audio = response.get("audio")
timestamps = response.get("timestamps")
if not isinstance(audio, str) or not audio:
    raise ValueError("captioned response did not contain audio")
if not isinstance(timestamps, list):
    raise ValueError("captioned response did not contain timestamps")

validated = []
for value in timestamps:
    if not isinstance(value, dict):
        continue
    word = value.get("word")
    start = value.get("start_time")
    end = value.get("end_time")
    if not isinstance(word, str) or not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
        continue
    if start < 0 or end < start:
        continue
    validated.append({"word": word, "start_time": float(start), "end_time": float(end)})

audio_bytes = base64.b64decode(audio, validate=True)
if not audio_bytes:
    raise ValueError("captioned response decoded to empty audio")

for destination, payload in (
    (audio_destination, audio_bytes),
    (timestamp_destination, json.dumps(validated, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"),
):
    directory = os.path.dirname(destination) or "."
    descriptor, temporary = tempfile.mkstemp(prefix=".tts-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY
  then
    CAPTIONED_READY=1
  fi
fi

if [ "$CAPTIONED_READY" -ne 1 ]; then
  echo "Warning: precise TTS timestamps are unavailable; generating audio without word alignment." >&2
  rm -f "$CAPTION_RESPONSE_FILE" "$TIMESTAMPS_FILE" "$OUTPUT_FILE"
  if command -v python3 >/dev/null 2>&1; then
    PAYLOAD=$(python3 - "$TEXT" "$VOICE" <<'PY'
import json
import sys
print(json.dumps({
    "model": "kokoro",
    "input": sys.argv[1],
    "voice": sys.argv[2],
    "response_format": "mp3",
}))
PY
)
  else
    PAYLOAD="{\"model\":\"kokoro\",\"input\":\"$TEXT\",\"voice\":\"$VOICE\",\"response_format\":\"mp3\"}"
  fi
  set +e
  HTTP_CODE=$(curl -sS -X POST -H "Content-Type: application/json" -d "$PAYLOAD" \
    ${AUTH_OPTS[@]+"${AUTH_OPTS[@]}"} "$API_URL" -w "%{http_code}" -o "$OUTPUT_FILE" 2>"$TMP_ERR")
  CURL_STATUS=$?
  set -e
  if [ "$CURL_STATUS" -ne 0 ]; then
    echo "Error: failed to call TTS endpoint" >&2
    cat "$TMP_ERR" >&2 || true
    generation_failure_detail "TTS endpoint request failed"
    rm -f "$TMP_ERR" "$OUTPUT_FILE"
    exit 1
  fi
  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "Error: TTS request failed with HTTP $HTTP_CODE" >&2
    generation_failure_detail "TTS request failed with HTTP $HTTP_CODE"
    rm -f "$OUTPUT_FILE"
    exit 1
  fi
fi
rm -f "$TMP_ERR" "$CAPTION_RESPONSE_FILE"

if [ ! -s "$OUTPUT_FILE" ]; then
  echo "Error: Empty response from TTS server" >&2
  GENERATION_FAILURE_MESSAGE="TTS endpoint returned empty audio."
  rm -f "$OUTPUT_FILE"
  exit 1
fi

release_generation_slot

if [ "$NO_PLAY" -eq 1 ]; then
  if ! truthy "${TTS_INTERNAL_ATTACHMENT_GENERATION:-0}"; then
    persist_durable_status "generated" "$(date +%s)" || true
  fi
  emit_tts_result "generated"
  exit 0
fi

deliver_generated_audio
}

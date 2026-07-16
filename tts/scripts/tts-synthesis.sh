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
  release_speech_gate
  exit "$exit_code"
}

trap cleanup EXIT

update_existing_playback_status() {
  local status="$1"
  local state_dir item_file
  [ -n "${TTS_ITEM_ID:-}" ] || return 0
  state_dir="$(tts_state_dir)"
  item_file="$state_dir/items/$TTS_ITEM_ID.json"
  python3 - "$item_file" "$status" <<'PY'
import json
import fcntl
import os
import sys
import tempfile
import time

path, status = sys.argv[1:]
state_directory = os.path.dirname(os.path.dirname(path))
os.makedirs(state_directory, exist_ok=True)
lock_handle = open(os.path.join(state_directory, "operations.flock"), "a+")
fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
try:
    with open(path, encoding="utf-8") as handle:
        item = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
now = int(time.time())
item["status"] = status
if status == "playing":
    item["started_at"] = now
elif status in ("played", "failed"):
    item["completed_at"] = now
    item["is_unheard"] = status != "played"
directory = os.path.dirname(path)
descriptor, temporary = tempfile.mkstemp(prefix=".tts-playback-", dir=directory)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(item, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
    lock_handle.close()
PY
}

if [ -n "$PLAY_EXISTING_FILE" ]; then
  OUTPUT_FILE="$PLAY_EXISTING_FILE"
  if [ ! -s "$OUTPUT_FILE" ]; then
    echo "Error: playback file does not exist or is empty: $OUTPUT_FILE" >&2
    exit 1
  fi

  acquire_speech_gate

  update_existing_playback_status "playing"
  if command -v afplay >/dev/null 2>&1; then
    afplay "$OUTPUT_FILE"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$OUTPUT_FILE" >/dev/null 2>&1 || true
  else
    echo "Tip: open the file manually: $OUTPUT_FILE" >&2
  fi
  update_existing_playback_status "played"

  exit 0
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

if [ "$NO_PLAY" -eq 1 ]; then
  if ! truthy "${TTS_INTERNAL_ATTACHMENT_GENERATION:-0}"; then
    persist_durable_status "generated" "$(date +%s)" || true
  fi
  emit_tts_result "generated"
  exit 0
fi

echo "Generated TTS audio: $OUTPUT_FILE" >&2
if macos_menu_enabled && queue_macos_playback; then
  if [ "$ASK" -eq 1 ]; then
    wait_for_question_answer
  else
    emit_tts_result "queued"
  fi
  exit 0
fi

state_dir="$(tts_state_dir)"
if ! mkdir -p "$state_dir" 2>/dev/null; then
  state_dir="/tmp/tts-state"
  mkdir -p "$state_dir" 2>/dev/null || state_dir="/tmp"
fi
log_file="$state_dir/tts-playback-$(date +%Y%m%d-%H%M%S)-$$.log"
persist_durable_status "queued" || true
playback_args=(--play-existing "$OUTPUT_FILE")
if [ -n "$AGENT_NAME" ]; then
  playback_args+=(--agent-name "$AGENT_NAME")
fi
nohup env \
  TTS_CALLER_PPID="${TTS_CALLER_PPID:-$PPID}" \
  TTS_ITEM_ID="$ITEM_ID" \
  "$0" "${playback_args[@]}" \
  </dev/null >>"$log_file" 2>&1 &
pid=$!
disown "$pid" 2>/dev/null || true
printf 'Queued TTS playback in background: pid %s, log %s\n' "$pid" "$log_file" >&2
if [ "$ASK" -eq 1 ]; then
  wait_for_question_answer
else
  emit_tts_result "queued"
fi
}

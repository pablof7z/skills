# shellcheck shell=bash

queue_macos_playback() {
  local state_dir items_dir item_id item_file generation_duration
  local menu_command

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 is unavailable; unable to queue macOS playback." >&2
    return 1
  fi

  menu_command="${TTS_MENU_COMMAND:-$SCRIPT_DIR/tts-menu}"
  if [ ! -x "$menu_command" ]; then
    echo "Warning: TTS menu launcher is unavailable; unable to queue playback." >&2
    return 1
  fi

  state_dir="$(tts_state_dir)"
  items_dir="$state_dir/items"
  mkdir -p "$items_dir" || return 1

  item_id="$ITEM_ID"
  item_file="$items_dir/$item_id.json"
  generation_duration=$(( $(date +%s) - ITEM_CREATED_AT ))

  if ! write_macos_item_record "$item_file" "queued" "" "" "$generation_duration" "1"; then
    return 1
  fi

  if "$menu_command" start >/dev/null; then
    MACOS_GENERATION_ACTIVE=0
    MACOS_ITEM_FILE="$item_file"
    if python3 - "$item_file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    item = json.load(handle)
raise SystemExit(0 if any(
    value.get("kind") == "narrated_text" and value.get("status") == "preparing"
    for value in (item.get("attachments") or [])
) else 1)
PY
    then
      local attachment_log="$ITEM_DIRECTORY/attachment-generation.log"
      echo "Preparing narrated TTS attachments before returning..." >&2
      if "$SCRIPT_DIR/tts-attachment-worker" "$item_file" \
        </dev/null >>"$attachment_log" 2>&1; then
        echo "Prepared narrated TTS attachments." >&2
      else
        echo "Warning: narrated TTS attachment preparation failed; see $attachment_log" >&2
      fi
    fi
    local queue_summary global_pause queued_count system_muted
    queue_summary="$(python3 - "$state_dir" <<'PY'
import json
import os
import sys

state_dir = sys.argv[1]
items_dir = os.path.join(state_dir, "items")
queued = 0
if os.path.isdir(items_dir):
    for name in os.listdir(items_dir):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(items_dir, name), encoding="utf-8") as handle:
                item = json.load(handle)
        except (OSError, ValueError):
            continue
        if item.get("status") == "queued":
            queued += 1

paused = os.path.isfile(os.path.join(state_dir, "playback-paused"))
print(("paused" if paused else "active") + " " + str(queued))
PY
)"
    global_pause="${queue_summary%% *}"
    queued_count="${queue_summary##* }"
    system_muted="false"
    if command -v osascript >/dev/null 2>&1; then
      system_muted="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || printf 'false')"
    fi
    printf 'Queued TTS in macOS app: %s (%s queued)\n' "$item_id" "$queued_count" >&2
    if [ "${#ATTACHMENT_PATHS[@]}" -gt 0 ]; then
      printf 'Attached %s durable item(s): %s\n' "${#ATTACHMENT_PATHS[@]}" "$ITEM_DIRECTORY/attachments" >&2
    fi
    if [ "$global_pause" = "paused" ]; then
      echo "All TTS playback is paused. This audio was generated and queued, but it will not play until TTS is resumed in the TTS app." >&2
    fi
    if [ "$system_muted" = "true" ]; then
      echo "System output is muted. This audio was generated and queued; TTS playback is paused automatically until output is unmuted." >&2
    fi
    return 0
  fi

  echo "Warning: native TTS queue failed to start." >&2
  return 1
}

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

play_audio_directly() {
  local audio_file="$1"
  acquire_speech_gate
  update_existing_playback_status "playing"

  if command -v afplay >/dev/null 2>&1; then
    if ! afplay "$audio_file"; then
      update_existing_playback_status "failed"
      return 1
    fi
  elif command -v xdg-open >/dev/null 2>&1; then
    if ! xdg-open "$audio_file" >/dev/null 2>&1; then
      update_existing_playback_status "failed"
      return 1
    fi
  else
    echo "Error: no direct audio player is available." >&2
    update_existing_playback_status "failed"
    return 1
  fi

  update_existing_playback_status "played"
}

play_existing_audio() {
  local source_file="$PLAY_EXISTING_FILE"
  if [ ! -s "$source_file" ]; then
    echo "Error: playback file does not exist or is empty: $source_file" >&2
    return 1
  fi

  if ! macos_menu_enabled; then
    OUTPUT_FILE="$source_file"
    play_audio_directly "$OUTPUT_FILE"
    return
  fi

  local durable_output="$ITEM_DIRECTORY/message.mp3"
  if [ "$source_file" != "$durable_output" ]; then
    cp "$source_file" "$durable_output"
  fi
  OUTPUT_FILE="$durable_output"
  begin_durable_generation || {
    echo "Error: unable to create a durable item for existing audio." >&2
    return 1
  }
  if queue_macos_playback; then
    emit_tts_result "queued"
    return 0
  fi

  GENERATION_FAILURE_MESSAGE="The macOS playback owner is unavailable; audio was not started."
  echo "Error: $GENERATION_FAILURE_MESSAGE" >&2
  return 1
}

queue_direct_playback() {
  local state_dir log_file pid
  local playback_args=(--play-existing "$OUTPUT_FILE")
  state_dir="$(tts_state_dir)"
  if ! mkdir -p "$state_dir" 2>/dev/null; then
    state_dir="/tmp/tts-state"
    mkdir -p "$state_dir" 2>/dev/null || state_dir="/tmp"
  fi
  log_file="$state_dir/tts-playback-$(date +%Y%m%d-%H%M%S)-$$.log"
  persist_durable_status "queued" || true
  if [ -n "$AGENT_NAME" ]; then
    playback_args+=(--agent-name "$AGENT_NAME")
  fi
  if [ -n "$SUBJECT" ]; then
    playback_args+=(--subject "$SUBJECT")
  fi
  if [ -n "$SUMMARY" ]; then
    playback_args+=(--summary "$SUMMARY")
  fi
  nohup env \
    TTS_CALLER_PPID="${TTS_CALLER_PPID:-$PPID}" \
    TTS_INTERNAL_PLAYBACK=1 \
    TTS_ITEM_ID="$ITEM_ID" \
    "$SCRIPT_DIR/tts" "${playback_args[@]}" \
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

deliver_generated_audio() {
  echo "Generated TTS audio: $OUTPUT_FILE" >&2
  if ! macos_menu_enabled; then
    queue_direct_playback
    return
  fi
  if queue_macos_playback; then
    if [ "$ASK" -eq 1 ]; then
      wait_for_question_answer
    else
      emit_tts_result "queued"
    fi
    return 0
  fi

  GENERATION_FAILURE_MESSAGE="The macOS playback owner is unavailable; audio was not started."
  echo "Error: $GENERATION_FAILURE_MESSAGE" >&2
  return 1
}

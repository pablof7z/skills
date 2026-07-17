# shellcheck shell=bash

TTS_GENERATION_SLOT_HELD=0
TTS_GENERATION_SLOT_DIR=""
TTS_GENERATION_SLOT_POLL_SECONDS="${TTS_GENERATION_SLOT_POLL_SECONDS:-0.1}"

tts_generation_limit() {
  local limit="${TTS_MAX_PARALLEL_GENERATIONS:-}"
  if [ -z "$limit" ]; then
    limit="$(player_generation_limit 2>/dev/null || true)"
  fi
  limit="${limit:-2}"
  if [[ ! "$limit" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: TTS_MAX_PARALLEL_GENERATIONS must be a positive integer." >&2
    return 1
  fi
  printf '%s\n' "$limit"
}

player_generation_limit() {
  local preferences_file
  command -v python3 >/dev/null 2>&1 || return 1
  preferences_file="$(tts_state_dir)/player-preferences.json"
  [ -r "$preferences_file" ] || return 1
  python3 - "$preferences_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value = json.load(handle).get("maxParallelGenerations")
except (OSError, ValueError, AttributeError):
    raise SystemExit(1)
if isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 8:
    print(value)
else:
    raise SystemExit(1)
PY
}

release_generation_slot() {
  local owner_pid=""
  if [ "$TTS_GENERATION_SLOT_HELD" -ne 1 ] || [ -z "$TTS_GENERATION_SLOT_DIR" ]; then
    return 0
  fi

  if [ -r "$TTS_GENERATION_SLOT_DIR/owner" ]; then
    IFS= read -r owner_pid < "$TTS_GENERATION_SLOT_DIR/owner" || true
  fi
  if [ "$owner_pid" = "$$" ]; then
    rm -f "$TTS_GENERATION_SLOT_DIR/owner"
    rmdir "$TTS_GENERATION_SLOT_DIR" 2>/dev/null || true
  fi
  TTS_GENERATION_SLOT_HELD=0
  TTS_GENERATION_SLOT_DIR=""
}

generation_slot_is_stale() {
  local slot_dir="$1"
  local owner_pid=""
  local created_at=""
  local age

  if [ -r "$slot_dir/owner" ]; then
    {
      IFS= read -r owner_pid || true
      IFS= read -r created_at || true
    } < "$slot_dir/owner"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
      ! kill -0 "$owner_pid" 2>/dev/null
      return
    fi
  fi

  created_at="${created_at:-$(path_mtime_epoch "$slot_dir")}"
  if [[ "$created_at" =~ ^[0-9]+$ ]]; then
    age=$(( $(date +%s) - created_at ))
    [ "$age" -gt 10 ]
    return
  fi
  return 1
}

acquire_generation_slot() {
  local limit state_dir slots_dir slot_dir index warned=0
  limit="$(tts_generation_limit)" || return 1
  state_dir="$(tts_state_dir)"
  if ! mkdir -p "$state_dir" 2>/dev/null; then
    state_dir="/tmp/tts-state-${UID:-user}"
  fi
  slots_dir="$state_dir/generation-slots"
  if ! mkdir -p "$slots_dir" 2>/dev/null; then
    echo "Error: unable to create the shared TTS generation queue: $slots_dir" >&2
    return 1
  fi

  while true; do
    index=1
    while [ "$index" -le "$limit" ]; do
      slot_dir="$slots_dir/slot-$index"
      if mkdir "$slot_dir" 2>/dev/null; then
        TTS_GENERATION_SLOT_DIR="$slot_dir"
        TTS_GENERATION_SLOT_HELD=1
        {
          printf '%s\n' "$$"
          date +%s
        } > "$slot_dir/owner"
        return 0
      fi

      if generation_slot_is_stale "$slot_dir"; then
        rm -f "$slot_dir/owner"
        rmdir "$slot_dir" 2>/dev/null || true
      fi
      index=$(( index + 1 ))
    done

    if [ "$warned" -eq 0 ]; then
      echo "Waiting for an available TTS generation slot (limit: $limit)..." >&2
      warned=1
    fi
    sleep "$TTS_GENERATION_SLOT_POLL_SECONDS"
  done
}

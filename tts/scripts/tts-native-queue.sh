# shellcheck shell=bash

agent_identity() {
  if [ -n "$AGENT_NAME" ]; then
    printf 'name:%s\n' "$AGENT_NAME"
  else
    printf 'ppid:%s\n' "${TTS_CALLER_PPID:-$PPID}"
  fi
}

select_voice_from_seed() {
  local seed="$1"
  local checksum index
  checksum=$(printf '%s' "$seed" | cksum | awk '{ print $1 }')
  index=$(( checksum % ${#DETERMINISTIC_VOICES[@]} ))
  printf '%s\n' "${DETERMINISTIC_VOICES[$index]}"
}

prepend_spoken_segment() {
  local segment="$1"
  local text="$2"
  case "$segment" in
    *[.!?])
      printf '%s %s\n' "$segment" "$text"
      ;;
    *)
      printf '%s. %s\n' "$segment" "$text"
      ;;
  esac
}

MACOS_GENERATION_ACTIVE=0
MACOS_ITEM_FILE=""
GENERATION_FAILURE_MESSAGE=""

generation_failure_detail() {
  local fallback="$1"
  local response_detail=""

  if [ -s "$TMP_ERR" ]; then
    response_detail="$(tail -n 1 "$TMP_ERR" | tr '\n' ' ' | cut -c1-240)"
  fi
  if [ -n "$response_detail" ]; then
    GENERATION_FAILURE_MESSAGE="$fallback: $response_detail"
  else
    GENERATION_FAILURE_MESSAGE="$fallback"
  fi
}

write_macos_item_record() {
  local destination="$1"
  local status="$2"
  local completed_at="${3:-}"
  local error_message="${4:-}"
  local generation_duration="${5:-}"
  local harness session_id iterm_session_id workspace inferred_agent

  harness="$(infer_harness)"
  session_id="$(infer_session_id)"
  iterm_session_id="$(infer_iterm_session_id)"
  workspace="${TTS_WORKSPACE:-${WTG_WORKTREE_PATH:-$(pwd -P)}}"
  inferred_agent="${AGENT_NAME:-${TTS_AGENT_NAME:-${TENEX_AGENT_NAME:-}}}"

  python3 - \
    "$destination" \
    "$ITEM_ID" \
    "$DISPLAY_TEXT" \
    "$SUBJECT" \
    "$SUMMARY" \
    "$inferred_agent" \
    "$harness" \
    "$session_id" \
    "$iterm_session_id" \
    "$workspace" \
    "$VOICE" \
    "$OUTPUT_FILE" \
    "$TIMESTAMPS_FILE" \
    "$ATTACHMENT_MANIFEST" \
    "$ITEM_DIRECTORY" \
    "$SCRIPT_DIR/tts" \
    "$ITEM_CREATED_AT" \
    "$status" \
    "$completed_at" \
    "$error_message" \
    "$generation_duration" \
    "$ASK" \
    "$NO_PLAY" \
    "$SUGGESTIONS_JSON" \
    "$QUESTION_BUNDLE_FILE" \
    "$PRIMARY_MESSAGE" <<'PY'
import json
import fcntl
import os
import sys
import tempfile

(
    destination,
    item_id,
    text,
    subject,
    summary,
    agent_name,
    harness,
    session_id,
    iterm_session_id,
    workspace,
    voice,
    output_file,
    timestamps_file,
    attachment_manifest,
    asset_directory,
    retry_command,
    created_at,
    status,
    completed_at,
    error,
    generation_duration,
    ask,
    no_play,
    suggestions_json,
    question_bundle_file,
    primary_message,
) = sys.argv[1:]

def optional(value):
    return value or None

word_timings = None
if timestamps_file and os.path.isfile(timestamps_file):
    try:
        with open(timestamps_file, encoding="utf-8") as handle:
            loaded = json.load(handle)
        if isinstance(loaded, list):
            word_timings = loaded
    except (OSError, ValueError):
        word_timings = None

attachments = None
if attachment_manifest and os.path.isfile(attachment_manifest):
    try:
        with open(attachment_manifest, encoding="utf-8") as handle:
            loaded = json.load(handle)
        if isinstance(loaded, list) and loaded:
            attachments = loaded
    except (OSError, ValueError):
        attachments = None

questions_preamble = None
questions = None
if question_bundle_file and os.path.isfile(question_bundle_file):
    try:
        with open(question_bundle_file, encoding="utf-8") as handle:
            loaded = json.load(handle)
        if isinstance(loaded, dict):
            questions_preamble = loaded.get("questions_preamble")
            questions = loaded.get("questions")
    except (OSError, ValueError):
        questions = None

state_directory = os.path.dirname(os.path.dirname(destination))
os.makedirs(state_directory, exist_ok=True)
lock_handle = open(os.path.join(state_directory, "operations.flock"), "a+")
fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)

existing = {}
existing_path = os.path.join(os.path.dirname(destination), f"{item_id}.json")
try:
    with open(existing_path, encoding="utf-8") as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict):
        existing = loaded
except (OSError, ValueError):
    pass

if isinstance(questions, list):
    existing_questions = {
        value.get("id"): value
        for value in (existing.get("questions") or [])
        if isinstance(value, dict) and value.get("id")
    }
    for question in questions:
        previous = existing_questions.get(question.get("id"))
        if not previous:
            continue
        if previous.get("status") and previous.get("status") != "pending":
            question["status"] = previous["status"]
            question["response"] = previous.get("response")
        elif previous.get("response") is not None:
            question["response"] = previous["response"]

item = {
    "id": item_id,
    "text": text,
    "subject": optional(subject),
    "summary": optional(summary),
    "agent_name": optional(agent_name),
    "harness": optional(harness),
    "session_id": optional(session_id),
    "iterm_session_id": optional(iterm_session_id),
    "workspace": optional(workspace),
    "voice": voice,
    "output_file": output_file,
    "status": status,
    "created_at": int(created_at),
    "started_at": None,
    "completed_at": int(completed_at) if completed_at else None,
    "duration": None,
    "error": optional(error),
    "word_timings": word_timings,
    "attachments": attachments,
    "asset_directory": optional(asset_directory),
    "retry_command": optional(retry_command),
    "generation_duration": float(generation_duration) if generation_duration else None,
    "is_unheard": True,
    "kind": "question" if ask == "1" else "speech",
    "question_status": existing.get("question_status", "pending") if ask == "1" else None,
    "suggestions": json.loads(suggestions_json) if ask == "1" else [],
    "response": existing.get("response"),
    "is_archived": existing.get("is_archived", False),
    "archived_at": existing.get("archived_at"),
    "archive_reason": existing.get("archive_reason"),
    "archived_by": existing.get("archived_by"),
    "superseded_by": existing.get("superseded_by", []),
    "playback_requested": existing.get("playback_requested", no_play != "1"),
    "playback_initiator": existing.get("playback_initiator", "automatic"),
    "engagement": existing.get("engagement", "unknown"),
    "user_activity": existing.get("user_activity"),
    "questions_preamble": questions_preamble,
    "questions": questions,
    "primary_message": optional(primary_message),
}

descriptor, temporary = tempfile.mkstemp(prefix=f".{item_id}.", suffix=".tmp", dir=os.path.dirname(destination))
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(item, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, destination)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
    lock_handle.close()
PY
}

begin_macos_generation() {
  local state_dir items_dir item_id item_file
  local menu_command

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  menu_command="${TTS_MENU_COMMAND:-$SCRIPT_DIR/tts-menu}"
  if [ ! -x "$menu_command" ]; then
    return 1
  fi

  state_dir="$(tts_state_dir)"
  items_dir="$state_dir/items"
  mkdir -p "$items_dir" || return 1

  item_id="$ITEM_ID"
  item_file="$items_dir/$item_id.json"
  if ! write_macos_item_record "$item_file" "generating"; then
    return 1
  fi

  if "$menu_command" start >/dev/null; then
    MACOS_GENERATION_ACTIVE=1
    MACOS_ITEM_FILE="$item_file"
    return 0
  fi

  return 1
}

begin_durable_generation() {
  local state_dir items_dir item_file
  command -v python3 >/dev/null 2>&1 || return 1
  state_dir="$(tts_state_dir)"
  items_dir="$state_dir/items"
  mkdir -p "$items_dir" || return 1
  item_file="$items_dir/$ITEM_ID.json"
  if ! write_macos_item_record "$item_file" "generating"; then
    return 1
  fi
  MACOS_GENERATION_ACTIVE=1
  MACOS_ITEM_FILE="$item_file"
}

persist_durable_status() {
  local status="$1"
  local completed_at="${2:-}"
  local state_dir items_dir item_file generation_duration
  state_dir="$(tts_state_dir)"
  items_dir="$state_dir/items"
  mkdir -p "$items_dir" || return 1
  item_file="$items_dir/$ITEM_ID.json"
  generation_duration=$(( $(date +%s) - ITEM_CREATED_AT ))
  write_macos_item_record "$item_file" "$status" "$completed_at" "" "$generation_duration"
  MACOS_GENERATION_ACTIVE=0
  MACOS_ITEM_FILE="$item_file"
}

emit_tts_result() {
  local status="$1"
  python3 - "$ITEM_ID" "$status" "$OUTPUT_FILE" <<'PY'
import json
import sys
print(json.dumps({"id": sys.argv[1], "status": sys.argv[2], "output_file": sys.argv[3]}, sort_keys=True))
PY
}

wait_for_question_answer() {
  local menu_command="${TTS_MENU_COMMAND:-$SCRIPT_DIR/tts-menu}"
  printf 'Question pending. Blocking for up to %s; final output will contain the answer or bounded follow-up guidance.\n' "$ASK_WAIT" >&2
  "$menu_command" queue wait "$ITEM_ID" --timeout "$ASK_WAIT"
}

mark_macos_generation_failed() {
  local completed_at generation_duration
  [ "$MACOS_GENERATION_ACTIVE" -eq 1 ] || return 0
  [ -n "$MACOS_ITEM_FILE" ] || return 0
  MACOS_GENERATION_ACTIVE=0
  completed_at="$(date +%s)"
  generation_duration=$(( completed_at - ITEM_CREATED_AT ))
  if write_macos_item_record \
    "$MACOS_ITEM_FILE" \
    "failed" \
    "$completed_at" \
    "${GENERATION_FAILURE_MESSAGE:-Speech generation failed.}" \
    "$generation_duration"; then :; fi
}

discard_macos_generation() {
  MACOS_GENERATION_ACTIVE=0
}

queue_macos_playback() {
  local state_dir items_dir item_id item_file generation_duration
  local menu_command

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 is unavailable; using fallback TTS playback." >&2
    discard_macos_generation
    return 1
  fi

  menu_command="${TTS_MENU_COMMAND:-$SCRIPT_DIR/tts-menu}"
  if [ ! -x "$menu_command" ]; then
    echo "Warning: TTS menu launcher is unavailable; using fallback playback." >&2
    discard_macos_generation
    return 1
  fi

  state_dir="$(tts_state_dir)"
  items_dir="$state_dir/items"
  mkdir -p "$items_dir" || return 1

  item_id="$ITEM_ID"
  item_file="$items_dir/$item_id.json"
  generation_duration=$(( $(date +%s) - ITEM_CREATED_AT ))

  if ! write_macos_item_record "$item_file" "queued" "" "" "$generation_duration"; then
    discard_macos_generation
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

  MACOS_GENERATION_ACTIVE=0
  echo "Warning: native TTS queue failed to start; using fallback playback." >&2
  return 1
}

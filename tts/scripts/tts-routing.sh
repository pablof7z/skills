# shellcheck shell=bash

paired_tts_available() {
  python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1])))
from tts_remote_state import active_peer

raise SystemExit(0 if active_peer() else 1)
PY
}

route_ordinary_tts_if_needed() {
  if [ -n "${KOKORO_API_ENDPOINT:-}" ] || truthy "${TTS_FORCE_LOCAL:-0}"; then
    return 0
  fi
  if [ "$NO_PLAY" -eq 1 ] || [ -n "$PLAY_EXISTING_FILE" ] || [ "$INTERNAL_CALL" -eq 1 ]; then
    return 0
  fi
  if ! paired_tts_available; then
    return 0
  fi

  local remote_message="${PRIMARY_MESSAGE:-$DISPLAY_TEXT}"
  local remote_arguments=(
    remote speak
    --agent-name "$AGENT_NAME"
    --subject "$SUBJECT"
    --message "$remote_message"
  )
  local index
  for index in "${!ATTACHMENT_PATHS[@]}"; do
    remote_arguments+=( --attach "${ATTACHMENT_LABELS[$index]}" "${ATTACHMENT_PATHS[$index]}" )
  done
  if [ "$ASK" -eq 1 ]; then
    remote_arguments+=( --ask "$RAW_BUNDLE_JSON" --wait "$ASK_WAIT" )
  fi

  exec python3 "$SCRIPT_DIR/tts-remote-cli.py" "${remote_arguments[@]}"
}

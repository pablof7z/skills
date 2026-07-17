# shellcheck shell=bash

tts_state_dir() {
  if [ -n "${TTS_STATE_DIR:-}" ]; then
    printf '%s\n' "$TTS_STATE_DIR"
  elif [ -n "${XDG_STATE_HOME:-}" ]; then
    printf '%s/tts\n' "$XDG_STATE_HOME"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/.local/state/tts\n' "$HOME"
  else
    printf '/tmp/tts-state\n'
  fi
}

truthy() {
  case "${1:-}" in
    1|true|True|TRUE|yes|Yes|YES|on|On|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

first_environment_value() {
  local name value
  for name in "$@"; do
    value="${!name:-}"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 1
}

infer_harness() {
  local explicit
  explicit="$(first_environment_value TTS_HARNESS WTG_HARNESS 2>/dev/null || true)"
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
  elif [ -n "${TENEX_EDGE_SESSION_ID:-}" ] || [ -n "${TENEX_AGENT_NAME:-}" ]; then
    printf 'tenex-edge\n'
  elif [ -n "${CODEX_THREAD_ID:-}" ]; then
    printf 'codex\n'
  elif [ -n "${CLAUDE_SESSION_ID:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
    printf 'claude\n'
  fi
}

infer_session_id() {
  first_environment_value \
    TTS_SESSION_ID \
    TENEX_EDGE_SESSION_ID \
    CODEX_THREAD_ID \
    CLAUDE_SESSION_ID \
    WTG_SESSION_ID \
    2>/dev/null || true
}

infer_iterm_session_id() {
  [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || return 0
  printf '%s\n' "${ITERM_SESSION_ID:-}"
}

macos_menu_enabled() {
  [ "$(uname -s)" = "Darwin" ] && truthy "${TTS_MACOS_MENU:-1}"
}

SPEECH_GATE_HELD=0
SPEECH_GATE_DIR=""
SPEECH_GATE_POLL_SECONDS="${TTS_SPEECH_GATE_POLL_SECONDS:-0.2}"
SPEECH_GATE_STALE_SECONDS="${TTS_SPEECH_GATE_STALE_SECONDS:-3600}"

process_is_alive() {
  local pid="$1"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  return 1
}

path_mtime_epoch() {
  local path="$1"
  stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || true
}

release_speech_gate() {
  if [ "$SPEECH_GATE_HELD" -ne 1 ] || [ -z "$SPEECH_GATE_DIR" ]; then
    return 0
  fi

  rm -rf "$SPEECH_GATE_DIR"
  SPEECH_GATE_HELD=0
}

lock_is_stale() {
  local owner_file="$1"
  local owner_pid=""
  local owner_started=""
  local now age

  if [ -r "$owner_file" ]; then
    {
      IFS= read -r owner_pid || true
      IFS= read -r owner_started || true
    } < "$owner_file"
  else
    owner_started="$(path_mtime_epoch "${owner_file%/owner}")"
  fi

  if [ -n "$owner_pid" ] && ! process_is_alive "$owner_pid"; then
    return 0
  fi

  if [[ "$owner_started" =~ ^[0-9]+$ ]] && [[ "$SPEECH_GATE_STALE_SECONDS" =~ ^[0-9]+$ ]]; then
    now=$(date +%s)
    age=$(( now - owner_started ))
    if [ "$age" -gt "$SPEECH_GATE_STALE_SECONDS" ]; then
      return 0
    fi
  fi

  return 1
}

acquire_speech_gate() {
  local state_dir owner_file warned=0
  state_dir="$(tts_state_dir)"
  if ! mkdir -p "$state_dir" 2>/dev/null; then
    state_dir="/tmp/tts-state"
    mkdir -p "$state_dir" 2>/dev/null || state_dir="/tmp"
  fi

  SPEECH_GATE_DIR="$state_dir/speech.lock"
  owner_file="$SPEECH_GATE_DIR/owner"

  while true; do
    if mkdir "$SPEECH_GATE_DIR" 2>/dev/null; then
      SPEECH_GATE_HELD=1
      {
        printf '%s\n' "$$"
        date +%s
      } > "$owner_file" 2>/dev/null || true
      return 0
    fi

    if lock_is_stale "$owner_file"; then
      rm -rf "$SPEECH_GATE_DIR"
      continue
    fi

    if [ "$warned" -eq 0 ]; then
      echo "Waiting for active TTS speech to finish..." >&2
      warned=1
    fi
    sleep "$SPEECH_GATE_POLL_SECONDS"
  done
}

usage() {
  echo "Usage: ./scripts/tts [options] 'Your text here'" >&2
  echo "Generates speech in the foreground, then queues playback in the background." >&2
  echo "Options:" >&2
  echo "  --message text             Primary message; aim under 300 words (hard limit 330)." >&2
  echo "  --attach label path        Attach labeled Markdown, text, image, audio, or another file. Repeatable." >&2
  echo "  --agent-name seed          Required stable agent seed name." >&2
  echo "  --subject text             Required title; aim for 2 to 5 words, maximum 10." >&2
  echo "  --summary text             Required one-line player preview; it is not spoken." >&2
  echo "  --ask [json|@file]         Ask one legacy question or a structured question bundle." >&2
  echo "  --wait duration            Required with --ask; block for e.g. 30s, 5m, or 1h." >&2
  echo "  --suggestions json         Suggested answers as JSON [[title, description], ...]." >&2
  echo "  --no-play                  Generate without playback; JSON output includes the MP3 path." >&2
  echo "Example: ./scripts/tts --agent-name agent-seed --subject 'MCP Audio Verified' --summary 'Hosted audio generation now succeeds through MCP.' --message 'The fix is ready.'" >&2
}


normalize_space() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

normalize_literal_newlines() {
  python3 - "$1" <<'PY'
import sys

text = sys.argv[1]
# Agents occasionally pass JSON-style line breaks as literal characters. Turn
# those into real Markdown line breaks before storing, displaying, or speaking
# the update, while leaving every other character untouched.
text = text.replace("\\r\\n", "\n").replace("\\n", "\n").replace("\\r", "\n")
sys.stdout.write(text)
PY
}

strip_spoken_code_blocks() {
  python3 - "$1" <<'PY'
import re
import sys

text = sys.argv[1]
pattern = re.compile(r"```([^\n`]*)\n.*?```", re.DOTALL)

def replace(match):
    fence = match.group(1).strip()
    if not fence:
        return match.group(0)
    return " "

result = pattern.sub(replace, text)
result = re.sub(r"[ \t]+", " ", result)
result = re.sub(r"\n[ \t]*\n[ \t]*\n+", "\n\n", result)
sys.stdout.write(result.strip())
PY
}

safe_path_component() {
  python3 - "$1" <<'PY'
import hashlib
import re
import sys

value = sys.argv[1].strip()
slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-.").lower()
if not slug:
    slug = "session"
if len(slug) > 80:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:10]
    slug = slug[:69].rstrip("-.") + "-" + digest
print(slug)
PY
}

# shellcheck shell=bash

TTS_PRIMARY_MESSAGE_TARGET_WORDS=300
TTS_PRIMARY_MESSAGE_HARD_LIMIT_WORDS=330

word_count() {
  printf '%s\n' "$1" | awk '{ count += NF } END { print count + 0 }'
}

primary_message_word_limit_text() {
  local text="$1"

  text="$(normalize_literal_newlines "$text")"
  text="$(strip_spoken_code_blocks "$text")"
  normalize_space "$text"
}

validate_primary_message_word_limit() {
  local text="$1"
  local count

  count="$(word_count "$text")"
  if [ "$count" -le "$TTS_PRIMARY_MESSAGE_HARD_LIMIT_WORDS" ]; then
    return 0
  fi

  printf 'Error: primary TTS message contains %s words; the enforced limit is %s words.\n' \
    "$count" "$TTS_PRIMARY_MESSAGE_HARD_LIMIT_WORDS" >&2
  printf 'Keep the automatically played --message under %s words. Put the concise main corpus there, then split longer output into labeled chapter attachments with repeated --attach pairs.\n' \
    "$TTS_PRIMARY_MESSAGE_TARGET_WORDS" >&2
  return 1
}

validate_forwarded_primary_message_word_limit() {
  local command="${1:-}"
  local action="${2:-}"
  local text

  if [ "$command" != "remote" ] || [[ ! "$action" =~ ^(speak|generate)$ ]]; then
    return 0
  fi
  shift 2
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--message" ] && [ "$#" -gt 1 ]; then
      text="$(primary_message_word_limit_text "$2")"
      validate_primary_message_word_limit "$text"
      return
    fi
    shift
  done
}

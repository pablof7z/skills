#!/usr/bin/env bash
set -euo pipefail

base="${HOME}/.agents/home"
identifier="${1:-}"

if [[ -z "$identifier" ]]; then
  if [[ -n "${AGENT_IDENTITY:-}" ]]; then
    identifier="$AGENT_IDENTITY"
  elif [[ -n "${AGENT_NAME:-}" ]]; then
    identifier="$AGENT_NAME"
  elif [[ -n "${AGENT_SLUG:-}" ]]; then
    identifier="$AGENT_SLUG"
  elif [[ -n "${AGENT_IDENTIFIER:-}" ]]; then
    identifier="$AGENT_IDENTIFIER"
  elif [[ -n "${NAME:-}" ]]; then
    identifier="$NAME"
  else
    identifier="agent"
  fi
fi

if [[ ! "$identifier" =~ ^[0-9a-fA-F]{16,128}$ ]]; then
  identifier="$(printf '%s' "$identifier" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#[^a-z0-9._-]#-#g' \
    | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$identifier" ]]; then
    identifier="agent"
  fi
fi

mkdir -p "$base/$identifier"
printf '%s\n' "$base/$identifier"

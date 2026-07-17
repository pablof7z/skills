#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${ROOT}/scripts/install-fleet"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  local path="$1" expected="$2" label="$3"
  [[ -f "${path}" ]] || fail "${label}: missing ${path}"
  [[ "$(<"${path}")" == "${expected}" ]] \
    || fail "${label}: unexpected content"
  echo "ok: ${label}"
}

ORIGIN="${TMP}/origin.git"
SEED="${TMP}/seed"
git init --bare --initial-branch=main "${ORIGIN}" >/dev/null
git init --initial-branch=main "${SEED}" >/dev/null
git -C "${SEED}" config user.email test@example.com
git -C "${SEED}" config user.name 'Skill Fleet Test'
git -C "${SEED}" remote add origin "${ORIGIN}"

mkdir -p "${SEED}/scripts" "${SEED}/alpha" \
  "${SEED}/tts/scripts" "${SEED}/tts/mcp" \
  "${SEED}/meta-feedback/scripts"
cp "${SCRIPT}" "${SEED}/scripts/install-fleet"
chmod +x "${SEED}/scripts/install-fleet"
printf '%s\n' '---' 'name: alpha' '---' >"${SEED}/alpha/SKILL.md"
printf 'version one\n' >"${SEED}/alpha/content.txt"
printf '%s\n' '---' 'name: tts' '---' >"${SEED}/tts/SKILL.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${SEED}/tts/scripts/tts"
chmod +x "${SEED}/tts/scripts/tts"
printf 'tts mcp\n' >"${SEED}/tts/mcp/pyproject.toml"
printf '%s\n' '---' 'name: meta-feedback' '---' \
  >"${SEED}/meta-feedback/SKILL.md"
printf 'value = 1\n' >"${SEED}/meta-feedback/scripts/record_feedback.py"
git -C "${SEED}" add .
git -C "${SEED}" commit -m initial >/dev/null
git -C "${SEED}" push -u origin main >/dev/null

CHECKOUT="${TMP}/checkout"
git clone "${ORIGIN}" "${CHECKOUT}" >/dev/null
printf 'version two\n' >"${SEED}/alpha/content.txt"
printf 'current\n' >"${SEED}/alpha/current.txt"
git -C "${SEED}" add .
git -C "${SEED}" commit -m current >/dev/null
git -C "${SEED}" push origin main >/dev/null
EXPECTED="$(git -C "${SEED}" rev-parse HEAD)"

LOCAL_HOME="${TMP}/local-home"
REMOTE_HOME="${TMP}/remote-home"
FAKE_BIN="${TMP}/bin"
LOG="${TMP}/commands.log"
mkdir -p "${LOCAL_HOME}/.agents/skills/alpha/meta-feedback" \
  "${LOCAL_HOME}/.agents/skills/tts/sessions" \
  "${LOCAL_HOME}/.agents/skills/tts/mcp/.venv" \
  "${REMOTE_HOME}/.agents/skills/alpha" "${FAKE_BIN}"
printf 'stale\n' >"${LOCAL_HOME}/.agents/skills/alpha/stale.txt"
printf 'local feedback\n' \
  >"${LOCAL_HOME}/.agents/skills/alpha/meta-feedback/report.md"
printf 'session\n' >"${LOCAL_HOME}/.agents/skills/tts/sessions/item"
printf 'venv\n' >"${LOCAL_HOME}/.agents/skills/tts/mcp/.venv/state"
mkdir -p "${REMOTE_HOME}/old-alpha"
printf 'remote stale\n' >"${REMOTE_HOME}/old-alpha/stale.txt"
rmdir "${REMOTE_HOME}/.agents/skills/alpha"
ln -s "${REMOTE_HOME}/old-alpha" \
  "${REMOTE_HOME}/.agents/skills/alpha"
printf 'dirty checkout\n' >"${CHECKOUT}/LOCAL"

REAL_RSYNC="$(command -v rsync)"
cat >"${FAKE_BIN}/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  if [[ "${arg}" == fake-host:* ]]; then
    arg="${FLEET_REMOTE_HOME}/${arg#fake-host:}"
  fi
  args+=("${arg}")
done
printf 'rsync %s\n' "$*" >>"${FLEET_TEST_LOG}"
exec "${FLEET_REAL_RSYNC}" "${args[@]}"
EOF
cat >"${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="$1"
shift
[[ "${target}" == fake-host ]]
printf 'ssh %s\n' "${target}" >>"${FLEET_TEST_LOG}"
HOME="${FLEET_REMOTE_HOME}" "$@"
EOF
cat >"${FAKE_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
chmod +x "${FAKE_BIN}"/*

OUTPUT="${TMP}/output"
if ! HOME="${LOCAL_HOME}" \
  PATH="${FAKE_BIN}:${PATH}" \
  FLEET_REMOTE_HOME="${REMOTE_HOME}" \
  FLEET_REAL_RSYNC="${REAL_RSYNC}" \
  FLEET_TEST_LOG="${LOG}" \
    bash "${CHECKOUT}/scripts/install-fleet" fake-host >"${OUTPUT}" 2>&1; then
  cat "${OUTPUT}" >&2
  fail 'fleet installer failed'
fi

assert_file "${LOCAL_HOME}/.agents/skills/alpha/content.txt" \
  'version two' 'local host received origin/main'
assert_file "${REMOTE_HOME}/.agents/skills/alpha/content.txt" \
  'version two' 'remote host received origin/main'
assert_file "${LOCAL_HOME}/.agents/skills/alpha/current.txt" \
  'current' 'new catalog file installed'
[[ ! -e "${LOCAL_HOME}/.agents/skills/alpha/stale.txt" ]] \
  || fail 'local stale catalog file survived'
[[ ! -e "${REMOTE_HOME}/.agents/skills/alpha/stale.txt" ]] \
  || fail 'remote stale catalog file survived'
[[ ! -L "${REMOTE_HOME}/.agents/skills/alpha" ]] \
  || fail 'remote skill symlink was not replaced with a catalog copy'
assert_file "${LOCAL_HOME}/.agents/skills/alpha/meta-feedback/report.md" \
  'local feedback' 'meta-feedback preserved'
assert_file "${LOCAL_HOME}/.agents/skills/tts/sessions/item" \
  'session' 'TTS sessions preserved'
assert_file "${LOCAL_HOME}/.agents/skills/tts/mcp/.venv/state" \
  'venv' 'TTS environment preserved'
[[ ! -e "${LOCAL_HOME}/.agents/skill-backups" ]] \
  || fail 'installer created a backup directory'
[[ ! -e "${REMOTE_HOME}/.agents/skill-backups" ]] \
  || fail 'installer created a remote backup directory'
[[ -f "${CHECKOUT}/LOCAL" ]] || fail 'dirty checkout was modified'
[[ "$(git -C "${CHECKOUT}" rev-parse HEAD)" != "${EXPECTED}" ]] \
  || fail 'dirty checkout unexpectedly moved to origin/main'
grep -Fq 'fleet verified: local + 1 remote host(s)' "${OUTPUT}" \
  || fail 'success summary missing'
grep -Fq "commit: ${EXPECTED}" "${OUTPUT}" \
  || fail 'deployed commit missing from summary'
[[ "$(grep -Fc 'ssh fake-host' "${LOG}")" -ge 2 ]] \
  || fail 'remote host was not installed and activated'
echo 'ok: dirty checkout stayed untouched and fleet verified'

DARWIN_HOME="${TMP}/darwin-home"
mkdir -p "${DARWIN_HOME}/.agents/skills/tts/scripts" \
  "${DARWIN_HOME}/.agents/skills/tts/macos" \
  "${DARWIN_HOME}/.agents/skills/meta-feedback/scripts"
cp "${SEED}/tts/SKILL.md" "${DARWIN_HOME}/.agents/skills/tts/SKILL.md"
cp "${SEED}/tts/scripts/tts" \
  "${DARWIN_HOME}/.agents/skills/tts/scripts/tts"
cp "${SEED}/meta-feedback/scripts/record_feedback.py" \
  "${DARWIN_HOME}/.agents/skills/meta-feedback/scripts/record_feedback.py"
cat >"${DARWIN_HOME}/.agents/skills/tts/scripts/tts-menu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tts-menu %s\n' "$*" >>"${FLEET_TEST_LOG}"
case "${1:-}" in
  status) printf '%s\n' '{"current":null,"queued":[],"menu_pid":42}' ;;
  restart) ;;
  *) exit 2 ;;
esac
EOF
cat >"${FAKE_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
cat >"${FAKE_BIN}/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == build\ -c\ release\ --package-path* ]]
printf 'swift %s\n' "$*" >>"${FLEET_TEST_LOG}"
EOF
chmod +x "${DARWIN_HOME}/.agents/skills/tts/scripts/tts-menu" \
  "${FAKE_BIN}/swift"
HOME="${DARWIN_HOME}" PATH="${FAKE_BIN}:${PATH}" FLEET_TEST_LOG="${LOG}" \
  bash "${SCRIPT}" --activate-host test-commit >"${TMP}/darwin-output"
grep -Fq 'swift build -c release --package-path' "${LOG}" \
  || fail 'Darwin TTS app was not built'
grep -Fq 'tts-menu restart' "${LOG}" \
  || fail 'idle Darwin TTS app was not restarted'
echo 'ok: Darwin TTS app built and restarted'

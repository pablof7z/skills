# Paired Laptop TTS

Use this only when local TTS is not available or the user wants speech to play on
an attended laptop. Keep agent-facing instructions high level; the scripts own
the signing, relay, retry, and idempotency details.

## Pair

On the attended laptop:

```bash
<skill-dir>/scripts/tts pair offer --relay <relay-url>
```

Send the JSON `pair_code` to the agent host. On the agent host:

```bash
<skill-dir>/scripts/tts pair connect --code '<pair_code-json>'
```

The pairing code contains `version`, `product=tts`, `relay`, `laptop_pubkey`,
`pairing_id`, `expires_at`, and a raw one-use `secret`. Do not wrap it in another
secret scheme. Check, list, and revoke pairings with:

```bash
<skill-dir>/scripts/tts pair status
<skill-dir>/scripts/tts pair list
<skill-dir>/scripts/tts pair revoke <peer-id>
```

## Laptop Daemon

Run the durable listener on the attended laptop:

```bash
<skill-dir>/scripts/tts daemon start
<skill-dir>/scripts/tts daemon status
<skill-dir>/scripts/tts daemon stop
```

For foreground operation or supervised sessions:

```bash
<skill-dir>/scripts/tts daemon run --wait-seconds 30
```

The daemon deduplicates accepted requests and materializes them through the same
local queue/playback path used by ordinary `tts` calls.

## Send Speech

From the agent host:

```bash
<skill-dir>/scripts/tts remote speak \
  --agent-name "<seed-name>" \
  --subject "<5-to-10-word subject>" \
  --message "<spoken update>"
```

If `AGENT_NSEC` is set, that signer is used exactly for the request. Otherwise
the installed persistent TTS backend signer is used. The backend identity remains
the stable reply endpoint either way, and request metadata is retained on queued
items for attribution.

## Failure Modes

Remote text speech should work once paired and the laptop daemon is running.
Remote attachments are accepted only when the laptop can read the referenced
paths. If a path is unavailable, the daemon rejects the request with structured
JSON guidance; retry with text only or with a path that exists on the paired
laptop.

All waits are bounded. Command failures emit structured JSON errors on stderr
where practical. Tests use deterministic file transport; real relay transport can
use the optional `nak` adapter when available.

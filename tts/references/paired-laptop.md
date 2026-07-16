# Paired Laptop TTS

Use this only when local TTS is not available or the user wants speech to play on
an attended laptop. Keep agent-facing instructions high level; the scripts own
the signing, relay, retry, and idempotency details.

## Pair

On the attended laptop:

```bash
<skill-dir>/scripts/tts pair offer --relay <relay-url>
```

On macOS, the same flow is available from the TTS menu-bar icon under
**Pair New Computer…**. The pairing window creates the code and starts the
remote listener. The icon remains available after the player window closes;
it shows listener status, paired computers, and an unread-queue badge. Hide
the icon with **Settings… → Show TTS in the menu bar** if you prefer to use
only the Dock app.

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

If `AGENT_NSEC` is set, that signer signs the inner request for attribution.
The persistent TTS backend signs the outer transport event and remains the
stable reply endpoint. Without `AGENT_NSEC`, the backend signs both layers.
Private signer material is never included in the event payload.

## Failure Modes

Remote text speech should work once paired and the laptop daemon is running.
Remote attachments are accepted only when the laptop can read the referenced
paths. If a path is unavailable, the daemon rejects the request with structured
JSON guidance; retry with text only or with a path that exists on the paired
laptop.

All waits are bounded. Command failures emit structured JSON errors on stderr
where practical. Tests use deterministic file transport or a fake `nak`
executable; real relay transport uses `nak` for key generation, signing,
publishing, verification, and bounded fetches.

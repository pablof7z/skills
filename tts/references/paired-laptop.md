# Paired Laptop TTS

Use this only when local TTS is not available or the user wants speech to play on
an attended laptop. Keep agent-facing instructions high level; the scripts own
the signing, relay, retry, and idempotency details.

## Pair

On the attended laptop:

```bash
<skill-dir>/scripts/tts pair offer \
  --relay wss://relay.primal.net \
  --channel wss://nip29.f7z.io/tts
```

On macOS, the same flow is available from the TTS menu-bar icon under
**Pair New Computer…**. The pairing window creates the code and starts the
remote listener. The icon remains available after the player window closes;
it shows listener status, paired computers, and an unread-queue badge. Hide
the icon with **Settings… → Show TTS in the menu bar** if you prefer to use
only the Dock app.

Send the opaque `pair_code` to the agent host. On the agent host:

```bash
<skill-dir>/scripts/tts pair connect --code '<pair-code>'
```

The connect command waits until the receiving laptop has admitted the remote
backend as a channel admin. It reports `connected` only after that relay state
is confirmed; keep the receiving daemon running until it finishes.

The compact code encodes only the receiving peer pubkey, pairing relay,
configured NIP-29 channel, and a raw one-use secret. The pairing relay carries
the one-time secret event; the channel coordinate identifies the managed relay
and group used for permissions and speech. The pairing window remembers both.
Do not wrap the code in another secret scheme. Check, list, and revoke pairings with:

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
local queue/playback path used by ordinary `tts` calls. `daemon start` detaches
the listener, leaves it running until `daemon stop`, and is safe to repeat. On
macOS it also ensures the TTS app is running so the optional menu-bar item stays
available after the player window closes.

The listener periodically reconciles the managed channel and paired peer
permissions. If the relay restarts and loses channel state, the existing
pairing repairs itself without requiring a new pairing code.

## Send Speech

Ordinary `<skill-dir>/scripts/tts` invocations automatically use an approved
paired laptop when local synthesis is unavailable. Agents should not select the
transport for routine speech. Use the explicit command below only to target a
specific peer or diagnose remote delivery.

From the agent host:

```bash
<skill-dir>/scripts/tts remote speak \
  --agent-name "<seed-name>" \
  --subject "<5-to-10-word subject>" \
  --message "<spoken update>"
```

To ask from the remote host and block until the laptop user answers, add the
same structured question bundle and bounded wait used by local TTS:

```bash
<skill-dir>/scripts/tts remote speak \
  --agent-name "<seed-name>" \
  --subject "<5-to-10-word subject>" \
  --message "<spoken question preamble>" \
  --ask '<question-bundle-json>' \
  --wait 5m
```

The laptop presents the ordinary question UI. The remote process stays in the
foreground until the user answers, skips every question, or the bounded wait
expires. Its final JSON contains only the question IDs and human-readable answer
values. Answer attachments and laptop-local paths are never returned over the
relay. Remote ask bundles cannot contain attachments; provide their context in
the question text instead.

If `AGENT_NSEC` is set, the paired backend first ensures that pubkey is a member
of the configured TTS channel, then the agent key signs and publishes the
kind-9 request directly. The backend remains a stable channel admin. Replies
target the pubkey that signed the request rather than a separate reply endpoint.
Without `AGENT_NSEC`, the backend signs the request itself. Private signer
material is never included in the event payload.

The backend also publishes a signed replaceable kind-0 profile containing its
hostname on the pairing relay. The laptop periodically verifies that profile
and stores the hostname with the paired peer, so the menu shows a recognizable
endpoint name. Missing, invalid, or unavailable metadata never blocks pairing
or speech; the menu safely falls back to a shortened pubkey.

For questions, the kind-9 event tags are the authoritative UI model: `title`,
`message`, optional `preamble`, repeated `question`, `label`, `description`, and
`option` tags, plus the bounded `wait`. Event content is a deterministic
Markdown rendering of those tags so an ordinary NIP-29 client can read and
understand the question. The laptop UI ignores that rendering and reconstructs
its local question bundle from the tags.

Question replies reference the request with `e`, target its author with `p`,
and carry one repeated `answer` tag per answered question. Each answer tag is
`["answer", <question-id>, <value>...]`, so multiple-choice answers remain one
compact tag with several human-readable values. Reply content is the equivalent
readable Markdown. The wire format contains no stringified ask or response JSON,
request UUID, product marker, answered-status marker, suggestion IDs, UI
interaction metadata, generated item records, or laptop filesystem paths.

Pairings created by versions that used expiring JSON codes must be recreated
before direct agent signing can be used. Generate a fresh compact code on the
laptop and pair again so the backend receives channel-admin permission.

## Failure Modes

Remote text speech should work once paired and the laptop daemon is running.
Remote attachments are passed into the ordinary local TTS attachment flow only
when the laptop can read the referenced paths. If a path is unavailable, the
daemon rejects the request with an error tag and readable Markdown guidance;
retry with text only or with a path that exists on the paired laptop.

All waits are bounded. Relay reads are scoped to the laptop and its paired
channels, paginated, and resumed from a durable cursor. Command failures emit
structured JSON errors on stderr without exposing signer material. Tests use
deterministic file transport or a fake `nak` executable; real relay transport
uses `nak` for key generation, signing, publishing, verification, and bounded
fetches. Pairing uses one p-targeted ephemeral event carrying the one-use
secret. The receiving app admits the backend as a member and admin of its
configured TTS channel; the backend can then admit the agent pubkeys it
represents before they publish directly.

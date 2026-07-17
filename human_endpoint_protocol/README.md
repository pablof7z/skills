# Human Endpoint Protocol

Issue #191 establishes a shared contract for pairing an attended laptop with a
persistent backend over Nostr.

The TTS skill can be copied as an independent folder, so this package is the
canonical contract, executable fixture source, and local development runtime.
The artifact-local `tts/scripts/tts-human-endpoint` entrypoint delegates here
when the repository checkout is present and otherwise fails with structured
JSON.

## Pairing

The laptop is the attended endpoint. It creates a short-lived product-specific
pairing code with:

- `version`
- `product`
- `relay`
- `laptop_pubkey`
- `pairing_id`
- `expires_at`
- `secret`

The backend is the persistent endpoint. It generates or loads a per-product
identity, publishes kind:0 metadata named like `<hostname> <product> daemon`,
and publishes a signed ephemeral pairing request containing the raw one-use
secret. The laptop validates version, product, expiry, pairing id, and secret,
consumes the pairing once, then persists the backend identity and NIP-29 group
configuration. Readers may accept the historical `relay_url` alias for
backward compatibility, but executable vectors serialize only `relay`.

## Messages

Ordinary requests and replies are kind:9 NIP-29 group messages. Requests carry
`d` correlation tags, `p` tags for the intended laptop, and `h` tags for the
product group. Replies `e`-tag the signed request event id, `p`-tag the backend,
and repeat the `h` product group. Consumers validate approved author, target,
product group, correlation, and replay before acting.

## Operations

Durable state is JSON-backed. Waits must be bounded. Revoked backends are
rejected before request handling. Transport errors are structured JSON errors.
The deterministic fake relay is for tests only; real publishing and querying are
provided by the thin `nak` adapter. `nak` signing reads `NOSTR_SECRET_KEY` from
the environment; the shared CLI does not accept nsec values on argv.

Run the shared vectors:

```bash
scripts/human-endpoint vectors
```

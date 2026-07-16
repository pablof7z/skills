# Human Endpoint Protocol

Issue #191 establishes a shared contract for pairing an attended laptop with a
persistent backend over Nostr.

The repository cannot rely on one installed runtime module for both consumers:
top-level skills are copied as independent folders, while WorktreeGuard is
installed as a plugin. This package is therefore the canonical contract,
executable fixture source, and local development runtime. Artifact-local
entrypoints in `tts/scripts/tts-human-endpoint` and
`plugins/worktree-guard/bin/wtg-human-endpoint` delegate here when the repository
checkout is present and otherwise fail with structured JSON.

## Pairing

The laptop is the attended endpoint. It creates a short-lived product-specific
pairing code with:

- `version`
- `product`
- `relay_url`
- `laptop_pubkey`
- `pairing_id`
- `expires_at`
- `secret`

The backend is the persistent endpoint. It generates or loads a per-product
identity, publishes kind:0 metadata named like `<hostname> <product> daemon`,
and publishes a signed ephemeral pairing request containing the raw one-use
secret. The laptop validates version, product, expiry, pairing id, and secret,
consumes the pairing once, then persists the backend identity and NIP-29 group
configuration.

## Messages

Ordinary requests and replies are kind:9 NIP-29 group messages. Requests carry
product correlation tags such as `["d", "<request id>"]` and p-tags for the
intended endpoint. Replies e-tag the signed request event id and p-tag the
backend. Duplicate request and reply events are idempotent.

## Operations

Durable state is JSON-backed. Waits must be bounded. Revoked backends are
rejected before request handling. Transport errors are structured JSON errors.
The deterministic fake relay is for tests only; real publishing is provided by
the thin `nak` adapter.

Run the shared vectors:

```bash
scripts/human-endpoint vectors
```

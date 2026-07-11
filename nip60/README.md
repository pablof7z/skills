# NIP-60 Cashu Wallets

## A wallet is a state machine for money that lives across systems

In a Nostr Cashu wallet, no single database row tells the whole truth. Value exists as proofs issued by mints. Wallet state is represented through encrypted events on relays. Deposits and sends pass through pending states. Nutzaps cross public Nostr events and private redemption keys. Recovery must reconstruct enough of that history to avoid losing or reusing value.

The `nip60` skill gives an agent the implementation model needed to reason across those boundaries instead of treating the wallet as a balance plus a few API calls.

## What it connects

- **NIP-60:** encrypted wallet configuration, token storage, transaction history, reserves, quotes, and backup events.
- **NIP-61:** mint lists, P2PK receiving keys, public nutzap events, redemption, and status transitions.
- **NIP-87:** mint discovery and the trust questions that come with choosing where value is issued.
- **NDK wallet APIs:** concrete TypeScript flows for creating, loading, funding, sending, receiving, monitoring, and recovering a wallet.

The guide includes event-kind references, lifecycle examples, token consolidation, relay strategy, multiple-mint behavior, error handling, and the security properties that should remain visible while implementing the happy path.

## Use it on a real wallet question

```text
$nip60 review this NDK wallet flow for proof reuse, pending-state loss, and incorrect Nostr event handling.
```

Or start from a feature:

```text
$nip60 implement nutzap receiving with explicit redemption and failure states.
```

The expected result is code and reasoning that account for the full value lifecycle, not an isolated SDK snippet.

## Safety boundary

This skill is implementation guidance, not a security audit, mint endorsement, or custody product. Wallet code can touch private keys, signed events, ecash proofs, relays, and real funds. Verify current NIP text and current library behavior, test with disposable value, and review key storage and proof-state transitions independently before production use.

Read [SKILL.md](SKILL.md) for the complete event reference and implementation guide.

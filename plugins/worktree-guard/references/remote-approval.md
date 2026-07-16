# Remote Approval Reference

This reference is for debugging and implementation work. Agents should prefer
the high-level commands in `README.md`.

## Workflow

1. On the attended laptop, run `wtg pair offer --relay <relay-url>`.
2. On the server, run the printed `wtg pair connect '<pair-code>'` command.
3. Keep `wtg daemon laptop --timeout <seconds>` running on the attended laptop.
4. Keep `wtg daemon server --timeout <seconds>` running on the server when
   decisions should be processed outside a single `request-base-access` wait.
5. Agents still request access with `wtg request-base-access --repo <repo>
   --reason "<reason>" --scope session --wait --timeout <seconds>`.

## Pairing

Pair codes are JSON and contain:

- `version`
- `product: worktree-guard`
- `relay`
- `laptop_pubkey`
- `pairing_id`
- `created_at`
- `expires_at`
- `secret`

The secret is raw and one-use by workflow convention. There is no HMAC and no
pairing encryption. On connect, the server creates or loads a persistent WTG
backend identity, publishes a kind `0` profile named `<hostname> wtg daemon`,
approves the laptop peer locally, and publishes an ephemeral pairing event that
p-tags the laptop and includes the raw secret.

## Approval Events

Remote authorization requests are signed kind `9` group messages. Requests
p-tag the laptop daemon and include operation, worktree, repository, reason,
session, and TTL context in JSON content.

Decisions are signed kind `9` group messages that e-tag the original request.
Supported decision values are `allow-once`, `allow-session`, and `deny`.

The server policy remains authoritative. The server accepts only decisions from
approved peers, for known pending requests, within the request window, and only
once. Unknown, late, malformed, unapproved, or replayed decisions fail closed.

## Transport

Production use defaults to a thin `nak` adapter. Tests set:

```bash
WTG_TRANSPORT=fake
WTG_FAKE_RELAY_FILE=/tmp/wtg-relay.jsonl
```

The fake transport is deterministic JSONL storage and must be used for tests;
tests must not depend on public relays.

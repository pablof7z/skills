# Remote Approval Reference

This reference is for debugging and implementation work. Agents should prefer
the high-level commands in `README.md`.

## Workflow

1. On the attended laptop, run `wtg pair offer --relay <relay-url>`.
2. On the server, run the printed `wtg pair connect '<pair-code>'` command.
3. Run `wtg daemon laptop start --timeout <seconds>` on the attended laptop.
4. Run `wtg daemon server start --timeout <seconds>` on the server when
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

The secret is raw and one-use by design. There is no HMAC and no pairing
encryption. On connect, the server creates or loads a persistent WTG backend
identity, publishes a kind `0` profile named `<hostname> wtg daemon`, approves
the laptop peer locally, and publishes a pairing event that p-tags the laptop,
includes `product`, `version`, `pairing_id`, and the raw secret, and is signed
by the backend identity.

## Approval Events

Remote authorization requests are signed kind `9` group messages. Requests
p-tag the laptop daemon, carry `h` and `product` tags for `worktree-guard`, and
include operation, worktree, repository, reason, session, TTL, and product
context in JSON content.

Decisions are signed kind `9` group messages that e-tag the original request.
They p-tag the backend, carry the same `h` and `product` tags, and include the
request id and product in JSON content. Supported decision values are
`allow-once`, `allow-session`, and `deny`.

The server policy remains authoritative. The server accepts only decisions
signed by the exact approved laptop for the known pending request, targeted at
the exact backend, within the request window, and only once. Unknown, late,
malformed, cross-product, unapproved, forged, wrong-target, or replayed
decisions fail closed.

## Transport

Production use defaults to a thin `nak` adapter. Tests set:

```bash
WTG_TRANSPORT=fake
WTG_FAKE_RELAY_FILE=/tmp/wtg-relay.jsonl
```

The fake transport is deterministic JSONL storage and must be used for tests;
tests must not depend on public relays.

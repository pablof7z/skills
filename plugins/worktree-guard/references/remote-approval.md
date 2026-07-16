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
- `group_id`
- `created_at`
- `expires_at`
- `secret`

The secret is raw and one-use by design. There is no HMAC and no pairing
encryption. On connect, the server creates or loads a persistent WTG backend
identity, publishes a kind `0` profile named `<hostname> wtg daemon`, approves
the laptop peer locally, and publishes a pairing event that p-tags the laptop,
targets the pair's `group_id`, includes `product`, `version`, `pairing_id`, and
the raw secret, and is signed by the backend identity.

Each pair gets a distinct NIP-29 group id. The laptop attempts kind `9007`
group creation when it offers the code. After accepting the one-use pairing
event, it attempts kind `9000` membership for the backend and kind `9002`
closed/public metadata. These administration events are best-effort: relays
without NIP-29 support can still carry the p- and h-targeted kind `9` messages.

## Approval Events

Remote authorization requests are signed kind `9` group messages. Requests
p-tag the laptop daemon, carry the pair-specific `h` group and a
`product=worktree-guard` tag, and include operation, worktree, repository,
reason, session, TTL, and product context in JSON content.

Decisions are signed kind `9` group messages that e-tag the original request.
They p-tag the backend, carry the same `h` and `product` tags, and include the
request id, session id, and product in JSON content. Supported decision values are
`allow-once`, `allow-session`, and `deny`.

The server policy remains authoritative. The server accepts only decisions
signed by the exact approved laptop for the known pending request, targeted at
the exact backend, within the request window, and only once. Unknown, late,
malformed, cross-product, unapproved, forged, wrong-target, or replayed
decisions fail closed.

Production relay reads use kind, recipient `p`, and pair `h` filters. Although
`nak req` verifies by default, WTG also verifies each returned event with
`nak verify` before protocol validation. Publication uses the event returned
by `nak`, including its real post-signing id; pending requests never rely on
the placeholder id assembled before the production signer runs.

## Transport

Production use defaults to a thin `nak` adapter. Tests set:

```bash
WTG_TRANSPORT=fake
WTG_FAKE_RELAY_FILE=/tmp/wtg-relay.jsonl
```

The fake transport is deterministic JSONL storage and must be used for tests;
tests must not depend on public relays.

---
name: ndk-core
description: Builder guide for using `@nostr-dev-kit/ndk` in apps, CLIs, bots, and services. Use when wiring relays, signers, subscriptions, publishing, profile or event loading, filters, or cache-backed Nostr flows.
---

# NDK Core

## Scope

Use this skill when building on top of `@nostr-dev-kit/ndk`, not when maintaining NDK internals.

It is for:

- app startup and relay configuration
- signer setup and key handling
- reading and publishing Nostr events
- subscription-driven UI and feed flows
- cache-backed or relay-backed data access
- CLIs, bots, or servers that need Nostr primitives without a framework wrapper

## Work the Task

Start from the public API, not `core/src/`.

Create NDK with the smallest setup that matches the job:

```ts
import NDK from "@nostr-dev-kit/ndk";

const ndk = new NDK({
  explicitRelayUrls: ["wss://relay.primal.net"],
  aiGuardrails: true,
});
```

Enable `aiGuardrails: true` during development. It catches the most common Nostr mistakes early, especially wrong filter values, bad tags, and blocking fetch anti-patterns.

Treat Nostr as an event stream, not a request-response API. For feeds, lists, profiles, reactions, and most screens, prefer `ndk.subscribe()` and render progressively as cached and live events arrive.

Prefer passing `onEvent`, `onEvents`, and `onEose` directly into `ndk.subscribe()` instead of attaching listeners afterward. That avoids missing cached or early relay events.

Treat `fetchEvents()` as a smell in product code. It blocks until EOSE. Use it only when the caller truly must wait before continuing. `fetchEvent()` is reasonable for genuine single-event resolution, replaceable lookups, or one-shot CLI steps.

Use hex pubkeys and event ids in filters. `npub`, `note`, `nprofile`, and `nevent` are user-facing encodings, not filter values.

Signers are optional for read-only work. Add a signer only when the flow needs to publish or sign HTTP auth events.

`NDKPrivateKeySigner` accepts an `nsec` directly:

```ts
import { NDKPrivateKeySigner } from "@nostr-dev-kit/ndk";

const signer = new NDKPrivateKeySigner("nsec1...");
ndk.signer = signer;
```

If the flow is direct HTTP plus local signing, you may not need relays or `await ndk.connect()` at all. Relay connections are for relay-backed reads and writes, not every use of NDK.

For publishing, create events with the `ndk` instance attached so signing and publishing use the configured signer and relay pool:

```ts
import { NDKEvent } from "@nostr-dev-kit/ndk";

const event = new NDKEvent(ndk, {
  kind: 1,
  content: "hello from ndk",
});

await event.publish();
```

Use cache adapters to make apps feel immediate, not to justify blocking fetch flows. Cached events should be rendered as they arrive, then updated with live relay data.

When building Node CLIs or servers, verify the package under plain `node`, not only Bun or a bundler.

## Run Commands

When you need examples or verification, prefer small real scripts over reading internals:

```bash
node your-script.js
```

## Read More

Read these public docs when needed:

- `core/README.md` for package-level behavior and guardrail positioning.
- `core/docs/getting-started/signers.md` for signer choices and examples.
- `core/snippets/` for public API usage patterns.

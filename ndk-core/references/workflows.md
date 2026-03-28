# NDK Builder Workflows

## Bootstrap an App

```ts
import NDK from "@nostr-dev-kit/ndk";

const ndk = new NDK({
  explicitRelayUrls: ["wss://relay.primal.net", "wss://relay.damus.io"],
  aiGuardrails: true,
});

await ndk.connect();
```

Add a signer or cache adapter only if the product needs them.

## Add a Private-Key Signer

```ts
import { NDKPrivateKeySigner } from "@nostr-dev-kit/ndk";

ndk.signer = new NDKPrivateKeySigner("nsec1...");
```

This works with an `nsec` directly.

## Subscribe to a Feed

```ts
const events: NDKEvent[] = [];

ndk.subscribe(
  { kinds: [1], "#t": ["nostr"] },
  { closeOnEose: false },
  {
    onEvents: (cached) => events.push(...cached),
    onEvent: (event) => events.push(event),
  }
);
```

If the product is UI-facing, this is usually better than `fetchEvents()`.

## Load One Specific Event

```ts
const event = await ndk.fetchEvent("nevent1...");
```

Also appropriate for event ids, `naddr`, and replaceable lookups.

## Publish a Note

```ts
import { NDKEvent, NDKKind } from "@nostr-dev-kit/ndk";

const event = new NDKEvent(ndk, {
  kind: NDKKind.Text,
  content: "hello from ndk",
});

await event.publish();
```

NDK fills `id`, `sig`, `pubkey`, and timestamps.

## Update a Replaceable Event

```ts
const metadata = await ndk.fetchEvent({ kinds: [0], authors: [pubkey] });
if (metadata) {
  metadata.content = JSON.stringify({ name: "new name" });
  await metadata.publishReplaceable();
}
```

Use `publishReplaceable()` when updating kinds like `0`, `3`, `10000-19999`, or parameterized replaceable events.

## Persist a Signer

```ts
const payload = ndk.signer?.toPayload();
localStorage.setItem("signer", payload!);

const restored = await ndkSignerFromPayload(localStorage.getItem("signer")!, ndk);
ndk.signer = restored;
```

This is the right high-level pattern for session persistence.

## Local-First Publishing

```ts
ndk.on("event:publish-failed", (event, error) => {
  console.error("failed to publish", event.id, error);
});

const event = new NDKEvent(ndk, { kind: 1, content: "draft" });
event.publish();
```

Use this when the product should feel immediate and recover from relay failures gracefully.

## Common Mistakes To Avoid

- Creating a new `NDK` instance per request or component
- Using `npub` or `note` in filters
- Using `fetchEvents()` for timelines and feeds
- Attaching subscription listeners after starting a subscription when early events matter
- Publishing replaceable events with stale timestamps instead of `publishReplaceable()`
- Performing one-off per-item fetches inside render loops

## How To Diagnose A Bad NDK Integration

Signs the implementation is off:

- the UI waits on blocking fetches before showing anything
- there is no cache but the app expects instant navigation
- relay connections are constantly recreated
- filters contain user-facing encodings instead of hex
- profile loading or related data happens as N separate imperative fetches

When those appear, simplify toward:

- one shared NDK instance
- subscriptions
- direct handlers
- cache-backed progressive rendering

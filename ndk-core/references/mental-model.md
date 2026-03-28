# NDK Mental Model

## What NDK Is For

NDK is the runtime you build Nostr products on top of. It gives you:

- relay connection and pooling
- subscription lifecycle management
- event wrappers and publishing
- signer abstractions
- cache integration
- outbox-aware relay selection

Use it as the durable Nostr layer under your app, bot, CLI, or service.

## The Right Default Architecture

In most apps, create one long-lived `NDK` instance and reuse it everywhere.

Why:

- relay connections and discovered relay state stay warm
- subscriptions can share the same relay pool
- cache, signer, mute state, and active user stay coherent
- you avoid reconnect churn and fragmented state

Treat NDK as application infrastructure, not a throwaway helper object you recreate per screen or action.

## Streams First

Nostr is fundamentally event-based. Product code should usually be subscription-driven.

Default approach:

- use `ndk.subscribe()` for feeds, profiles, reactions, conversations, and most screens
- render cached data immediately if available
- update as live relay events arrive
- stop subscriptions when the product scope ends

Smell:

- `await ndk.fetchEvents(filter)` to load a feed before rendering anything

Reason:

- `fetchEvents()` waits for EOSE
- many product surfaces do not need to block on EOSE
- stream-first UX feels faster and fits Nostr better

Use `fetchEvents()` only when you truly must block before continuing.

## Choosing Between subscribe, fetchEvent, and fetchEvents

Use `subscribe()` when:

- the feature is UI-facing
- you want progressive rendering
- the result may keep changing
- the user benefits from cache hits plus live updates

Use `fetchEvent()` when:

- you need one specific event
- you are resolving an event id, `nevent`, `naddr`, or replaceable event
- a CLI or one-shot flow genuinely needs a single resolved event before continuing

Use `fetchEvents()` when:

- you intentionally need a blocking multi-event query
- the workflow is imperative and cannot proceed without the complete result set

If you are unsure, `subscribe()` is usually the right answer.

## Handlers Belong In subscribe()

Prefer:

```ts
ndk.subscribe(
  { kinds: [1], authors: [pubkey] },
  { closeOnEose: false },
  {
    onEvents: (events) => hydrateInitialState(events),
    onEvent: (event) => appendLiveEvent(event),
    onEose: () => markInitialLoadFinished(),
  }
);
```

Avoid attaching listeners after creating the subscription if the early events matter. Cached and fast relay events can arrive immediately.

`onEvents` is especially useful when you want one batched initial cache load instead of many per-event updates.

## Filters

Filters are protocol-level values, not presentation-level values.

Use:

- hex pubkeys in `authors`
- hex event ids in `ids`
- numbers in `kinds`
- hex ids in `#e` and `#p` when appropriate

Do not use:

- `npub` in `authors`
- `note` or `nevent` in `ids`
- undefined values inside filter arrays

During development, `aiGuardrails: true` and the default filter validation are valuable because they catch these mistakes early.

## Relays and connect()

Use `await ndk.connect()` when the flow depends on relays:

- subscribing
- fetching from relays
- publishing to relays

You may not need relays at all when the flow is only:

- local signing
- serializing signers
- producing signed HTTP auth events for another protocol

That distinction matters for CLIs and server integrations.

## Signers

Read-only flows do not require a signer.

Add a signer when you need:

- to publish events
- relay authentication
- protocol-level signed auth outside relays
- encryption or decryption

Key point:

- `NDKPrivateKeySigner` accepts an `nsec` directly

Do not decode an `nsec` before passing it to the constructor unless you have a very specific reason.

## Publishing

Create events with the `ndk` instance attached:

```ts
const event = new NDKEvent(ndk, {
  kind: 1,
  content: "hello",
});

await event.publish();
```

Why:

- the configured signer is available
- relay selection is available
- optimistic and cache-aware behavior can work

For replaceable events, use `publishReplaceable()` when updating an existing value. Replaceable events depend on a fresh `created_at`.

## Local-First

NDK supports local-first behavior especially well when paired with a capable cache adapter.

Important ideas:

- optimistic publish can update local state before relay confirmation
- failed publishes should be surfaced to users
- unpublished events can be retried

This is for responsiveness, not for hiding errors. If a publish fails, the product should make that visible.

## AI Guardrails

Enable them in development:

```ts
const ndk = new NDK({
  explicitRelayUrls: ["wss://relay.primal.net"],
  aiGuardrails: true,
});
```

They help catch:

- bech32 values in filters
- invalid event shapes
- `fetchEvents()` misuse
- replaceable-event mistakes
- bad filter arrays

For agents, this is one of the highest-leverage settings in the package.

## Performance

The biggest practical performance wins usually come from:

- one durable NDK instance
- subscription-first design
- a cache adapter
- batched `onEvents` handling for initial cache results
- avoiding per-item imperative fetches in loops

If an implementation is doing one fetch per rendered event or waiting on EOSE for most screens, it is usually fighting the model.

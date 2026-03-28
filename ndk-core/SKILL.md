---
name: ndk-core
description: Deep builder guide for using `@nostr-dev-kit/ndk` in apps, bots, CLIs, and services. Use when designing or implementing relay setup, signers, subscriptions, publishing, event loading, profile loading, filter design, caching, local-first behavior, or Nostr product flows on top of NDK.
---

# NDK Core

## Scope

Use this skill when the task is to build with `@nostr-dev-kit/ndk`.

This skill is not for contributing to NDK internals. It is for agents that need to understand how to use NDK well in real product code.

Common triggers:

- bootstrapping an app's NDK instance
- choosing relays, outbox, and cache setup
- implementing feed, profile, timeline, or notification flows
- deciding between `subscribe()`, `fetchEvent()`, and `fetchEvents()`
- signer and session handling
- publishing text notes, metadata, lists, or replaceable events
- writing Node scripts, bots, or CLIs with NDK

## Work the Task

Read these in order:

1. `references/mental-model.md`
2. `references/workflows.md`

Read additional repo docs only when the task needs more detail:

- `core/docs/getting-started/usage.md`
- `core/docs/getting-started/signers.md`
- `core/docs/tutorial/local-first.md`
- `core/docs/tutorial/publishing.md`
- `core/docs/tutorial/filter-validation.md`
- `core/docs/tutorial/subscription-management.md`

## Non-Negotiables

- Think in streams, not request-response. Most product features should use `ndk.subscribe()`.
- Do not make UIs wait for EOSE before showing data unless the product truly requires that.
- Treat `fetchEvents()` as exceptional. It is a blocking operation.
- Use `fetchEvent()` for genuine single-event lookups and addressable/replaceable resolution.
- Filters use hex values, not bech32 user-facing encodings.
- `NDKPrivateKeySigner` accepts `nsec` directly.
- Enable `aiGuardrails: true` during development unless there is a concrete reason not to.

## What Good Looks Like

An agent using this skill should:

- initialize one durable NDK instance per app or process
- choose a signer and cache strategy that matches the environment
- model product features as subscriptions and progressive rendering
- publish events with the correct replaceable semantics
- avoid common filter and fetch anti-patterns
- understand when relays are required and when local signing alone is enough

## Read More

- `references/mental-model.md` for how to think about NDK-powered products
- `references/workflows.md` for concrete builder patterns and examples

---
name: ndk-core
description: Contributor guide for the `core/` package that ships `@nostr-dev-kit/ndk`. Use when editing relay and subscription behavior, event and signer logic, outbox routing, AI guardrails, shared utilities, or any public API exported from the core package.
---

# NDK Core

## Scope

Work in `core/` when the behavior belongs to the foundational NDK runtime instead of a wrapper package.

The main areas are:

- `src/ndk/` for main client behavior and entity access
- `src/relay/` for relay connectivity and auth
- `src/events/` for event helpers, wrappers, and tests
- `src/signers/` for signer adapters and serialization
- `src/outbox/` for relay selection and write routing
- `src/cache/` for cache-facing helpers
- `src/ai-guardrails/` for runtime validation and error guidance
- `src/thread/`, `src/dvm/`, `src/nip19/`, `src/nip49/` for focused protocol helpers

## Work the Task

Trace the public surface first. Changes in `core/src/index.ts`, `package.json` exports, or shared types usually ripple into `react`, `mobile`, `sessions`, `wallet`, `sync`, `wot`, and `blossom`.

Treat Nostr as an event stream, not a request-response API. For UI-facing and long-lived data flows, default to `ndk.subscribe()` and let consumers render progressively from cache hits and live relay events as they arrive.

Treat `fetchEvents()` as an exception, not the default. It is a blocking operation that waits for EOSE; only introduce or preserve it when the caller truly must block before continuing. `fetchEvent()` is appropriate for genuine single-event lookups, replaceable/addressable fetches, or imperative resolution steps, not for feeds, timelines, or most screens.

For signer-driven HTTP workflows, keep the core guidance concrete. `NDKPrivateKeySigner` accepts either hex private keys or `nsec` values directly; do not manually decode `nsec` before constructing it.

Do not require relays or `ndk.connect()` for flows that only need local signing and raw HTTP calls. A Blossom CLI can create an `NDK` instance, attach a signer, sign auth events, and talk directly to a media server without ever connecting to a relay.

Keep AI Guardrails aligned with the actual runtime rules. If you change filter expectations, event validation, or signer behavior, update the relevant guardrail code and tests instead of leaving docs to carry the mismatch.

Preserve the subscription ergonomics that prevent missed early events. Core docs and React hooks rely on passing `onEvent` and `onEvents` handlers directly into `ndk.subscribe()` so cached events and early relay events are delivered before downstream code attaches listeners later.

Prefer local tests near the modified subsystem. The package already has focused tests for relays, events, signers, outbox, and guardrails.

Preserve the distinction between end-user correctness and contributor ergonomics: core often owns both behavior and the explanatory error message.

If a core change affects user fetching, profile loading, subscriptions, signers, or cache-facing behavior that framework bindings depend on, validate it in at least one real consumer app. A clean SvelteKit smoke app using `createNDK`, registry-installed `user-profile`, and `cache-sqlite-wasm` exposed integration mismatches that package-local tests would not have caught.

Do not assume the framework packages consume core only through documented examples. The Svelte registry and package bindings can lock onto concrete prop shapes and helper behavior, so public core changes need cross-package verification.

Validate plain Node consumers when the output is meant for `npm` or `npx`. Bun and app bundlers can hide packaging issues that show up immediately when a package is executed by `node`.

## Run Commands

Use:

```bash
cd core
bun run build
bun run test
bun run test:coverage
bun run benchmark
```

Run targeted tests whenever possible, then rebuild if exports or generated types may have shifted.

## Read More

Read these files when the task needs more context:

- `core/README.md` for package-level behavior and guardrail positioning.
- `core/docs/getting-started/signers.md` for signer expectations.
- `core/src/signers/private-key/index.ts` when CLI or env-based secret handling matters.
- `core/snippets/` for API examples that may need updating after public changes.

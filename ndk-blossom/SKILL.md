---
name: ndk-blossom
description: Deep builder guide for using `@nostr-dev-kit/blossom` to upload files, publish and read Blossom server lists, authenticate to media servers, heal broken media URLs, generate imeta tags, and build resilient media flows on top of Nostr.
---

# NDK Blossom

## Scope

Use this skill when the task is to build with `@nostr-dev-kit/blossom`.

This skill is not for maintaining the Blossom package itself. It is for agents that need to understand how Blossom fits into NDK-powered products.

Common triggers:

- upload flows for images, video, audio, or documents
- publishing or editing a user's Blossom server list
- media display that should survive dead URLs
- list, delete, or existence-check tooling
- Node or browser code that needs Blossom auth and file handling
- converting uploads into nostr event tags

## Work the Task

Read these in order:

1. `references/mental-model.md`
2. `references/workflows.md`

Read additional repo docs only when needed:

- `blossom/README.md`
- `blossom/AGENT.md`
- `blossom/SPEC.md`

## Non-Negotiables

- Separate direct-server operations from relay-backed discovery.
- Understand `kind:10063` correctly: ordered `["server", "<https-url>"]` tags, first server is preferred.
- Understand `kind:24242` correctly: signed auth event used for Blossom server actions.
- Use `NDKBlossomList` when managing server-list events.
- Set a SHA256 calculator explicitly in serious app or CLI code.
- Convert successful uploads into `imeta` tags when publishing nostr content that references the blob.
- Do not block UI on healing or server-list discovery if the product can render progressively.

## What Good Looks Like

An agent using this skill should:

- know which Blossom actions require relays and which do not
- know which actions require a signer and which do not
- publish and update `kind:10063` lists correctly
- use upload results in nostr events correctly
- build resilient media flows that survive server failures
- handle Node and browser environment differences competently

## Read More

- `references/mental-model.md` for the protocol and product model
- `references/workflows.md` for concrete implementation patterns

---
name: ndk-blossom
description: Builder guide for using `@nostr-dev-kit/blossom` to upload files, manage blobs, optimize media URLs, heal broken Blossom links, and work with users' Blossom server lists.
---

# NDK Blossom

## Scope

Use this skill when building on top of `@nostr-dev-kit/blossom`, not when editing the Blossom package itself.

It is for:

- uploading files to Blossom servers
- checking, listing, or deleting blobs
- generating optimized media URLs
- recovering broken media URLs with user server lists
- publishing or reading `kind:10063` Blossom server lists
- Node, browser, or CLI tooling that talks to Blossom servers

## Work the Task

Separate direct-server work from relay-backed discovery.

Direct server operations do not need relays:

- `upload(file, { server })`
- `checkServerForBlob(server, sha256)`
- `getOptimizedUrl(url, opts)`

Relay-backed discovery does need relays:

- reading or publishing a user's `kind:10063` Blossom list
- healing broken URLs with `fixUrl(...)`
- any flow that depends on discovering the user's preferred Blossom servers from Nostr

Upload and delete flows need a signer. Read-only checks do not.

`NDKPrivateKeySigner` can take an `nsec` directly, so do not manually decode it first.

For uploads, always make the SHA256 path explicit in app or CLI code. Use the package's default calculator unless you truly need a custom one:

```ts
import NDK from "@nostr-dev-kit/ndk";
import { NDKBlossom, defaultSHA256Calculator } from "@nostr-dev-kit/blossom";

const ndk = new NDK({ signer });
const blossom = new NDKBlossom(ndk, signer);
blossom.setSHA256Calculator(defaultSHA256Calculator);

const imeta = await blossom.upload(file, {
  server: "https://blossom.primal.net",
  sha256Calculator: defaultSHA256Calculator,
});
```

In Node, remember this package uses web-style APIs. CLI code should work with `File`, `Blob`, `fetch`, and `crypto.subtle`, which are available in Node 18+.

Use user server lists correctly. NIP-B7 points to BUD-03, where a Blossom server list is a replaceable `kind:10063` event with ordered `["server", "<https-url>"]` tags. Order matters: the first server is the user's preferred default.

When you need to manage that list, prefer `NDKBlossomList` from `@nostr-dev-kit/ndk` instead of hand-rolling the event:

```ts
import { NDKBlossomList } from "@nostr-dev-kit/ndk";

const list = new NDKBlossomList(ndk);
list.servers = [
  "https://blossom.primal.net",
  "https://cdn.example.com",
];
await list.publishReplaceable();
```

Treat direct-server auth as HTTP plus a signed Nostr event. Real-world interop against `https://blossom.primal.net` showed that upload worked, `/list/<pubkey>` required auth for your own blobs, and delete could be slow enough that CLI tools should use sensible timeouts.

If you are building UI, do not block rendering on Blossom discovery. Show the original URL or local upload state immediately, then update when healing, upload progress, or server-list lookups complete.

## Run Commands

For app or CLI work, verify behavior against a real server when possible:

```bash
node your-script.js
```

## Read More

Read:

- `blossom/README.md` for the main API surface.
- `blossom/AGENT.md` for usage patterns and protocol notes.
- NIP-B7 in `nostr-protocol/nips` and BUD-03 in the Blossom spec for server-list semantics.

---
name: ndk-blossom
description: Contributor guide for the `blossom/` package. Use when changing Blossom upload and blob management flows, URL healing, mirroring, media-server auth, pluggable SHA256 behavior, or NDK integration for media storage.
---

# NDK Blossom

## Scope

Work in `blossom/` for media and blob protocol behavior rather than generic relay logic.

Important areas:

- `src/blossom.ts` for top-level API shape
- `src/upload/uploader.ts` for upload behavior
- `src/healing/url-healing.ts` for fallback and repair logic
- `src/utils/auth.ts`, `http.ts`, and `sha256.ts` for protocol plumbing
- `src/types/` for public data contracts

## Work the Task

Keep authenticated operations aligned with NDK signer behavior. Upload, delete, and mirroring flows rely on correct auth event generation.

Separate direct-server HTTP flows from relay-backed discovery flows. `upload(file, { server })`, `checkServerForBlob()`, and `getOptimizedUrl()` can work with only an `NDK` instance plus signer and do not require `ndk.connect()` or relays. URL healing and server-list discovery do require Nostr data.

For Node CLI work, verify the built package under plain `node`, not only Bun or a bundler. A real `node` run caught Node ESM import issues in `blossom/dist/` that Bun did not surface.

Use a real server when the task is about CLI or protocol interop. Testing against `https://blossom.primal.net` showed that authenticated upload worked, `/list/<pubkey>` required a kind `24242` auth event, and `DELETE /<hash>` could succeed but return slowly enough that CLI tools should consider timeouts.

Do not assume the package README or spec docs are perfectly current. The skill used to point at `docs/`, but this package currently has `README.md`, `SPEC.md`, `AGENT.md`, and `context/SPEC.md` instead. Some spec text mentions methods such as `addServer`, `removeServer`, or `mirrorBlob` that are not on the current public API; trust `src/blossom.ts` over stale prose.

When changing upload or healing behavior, inspect both the transport code and the public docs so supported workflows stay consistent.

Preserve the pluggable SHA256 hook. Browser, worker, or platform-specific callers may rely on replacing the default implementation.

Remember that this package uses web-style APIs even in Node. CLI code needs to convert local files into `File` objects and rely on Node 18+ globals such as `File`, `Blob`, `fetch`, and `crypto.subtle`.

List and delete have extra caveats. `listBlobs(user)` is for listing a user's blobs via their configured servers, and auth-sensitive servers may require the signer to match that same user. `deleteBlob(hash)` still works from the user's published Blossom server list rather than taking a direct `server` argument, so direct-server delete flows may need either the exported auth helpers from `@nostr-dev-kit/blossom` or a package-level API extension.

Keep Node-targeted source imports ESM-safe. Relative imports in package source need explicit `.js` suffixes when the emitted files are meant to run under plain Node ESM.

## Run Commands

Use:

```bash
cd blossom
bun run build
bun run test
```

## Read More

Read:

- `blossom/README.md` for package behavior and API examples.
- `blossom/SPEC.md` for the intended protocol surface, with the caveat that parts of it are stale.
- `blossom/AGENT.md` for the most useful implementation-oriented examples and protocol notes.
- `blossom/context/SPEC.md` only when you need extra historical context and are prepared to verify claims against source.
- `blossom/example/react/README.md` and `blossom/example/svelte/README.md` for how real consumers expect auth and upload flows to feel.

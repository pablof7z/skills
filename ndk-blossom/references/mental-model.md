# NDK Blossom Mental Model

## What Blossom Adds

Blossom gives Nostr apps a content-addressed media layer.

Core idea:

- the blob is identified by its SHA-256 hash
- the same blob can live on many servers
- the server URL is not the identity, the hash is

That means a good Blossom integration thinks in terms of:

- blobs
- hashes
- user server lists
- failover

not just one upload endpoint.

## Direct Server Operations vs Relay-Backed Discovery

This distinction is the most important one in the package.

Direct server operations:

- upload a file to a known server
- check whether a known server has a blob
- build optimized URLs from a known blob URL

These can work without relays. They need an `NDK` instance because the signer and shared NDK types are useful, but they do not inherently require `ndk.connect()`.

Relay-backed discovery:

- reading a user's Blossom server list
- publishing or updating that list
- healing broken URLs by looking across the user's preferred servers

These do require relays because the source of truth is Nostr data.

## Server Lists: NIP-B7 and BUD-03

For product behavior, the key rule is:

- a user's Blossom servers are published as a replaceable `kind:10063` event

The event shape is:

- empty content
- ordered `["server", "<https-url>"]` tags

The order matters. The first server is the preferred default.

This is not just metadata. Clients should use it to:

- decide where to upload
- decide where to look for missing blobs
- heal broken URLs

When the original blob URL dies, a good client can extract the hash, read the author's `kind:10063` list, and try the same hash on the listed servers.

## Auth: Kind 24242

Blossom uses signed nostr events for auth.

Conceptually:

- build a `kind:24242` auth event
- include an action tag like `upload`, `delete`, `list`, or `get`
- include an expiration
- include the blob hash when relevant
- send it as a `Nostr <base64>` authorization header

Builder takeaway:

- upload and delete usually need a signer
- list may need auth on some servers for the owner's own blobs
- existence checks and optimized URL generation usually do not

## Upload Result Shape

An upload returns an `NDKImetaTag`, not just a URL.

That matters because the result is meant to be turned into a nostr event tag.

Typical fields:

- `url`
- `x` for SHA-256 hash
- `m` for mime type
- `size`
- optionally dimensions, blurhash, alt text

The right follow-up is often:

- convert it into an `imeta` tag
- publish that tag inside a note, article, or other event

## Resilience Model

A weak Blossom integration treats the returned URL as permanent.

A strong Blossom integration treats the URL as one currently working location for a hash.

That leads to better behavior:

- store the hash and `imeta`, not just the raw URL
- prefer the user's own server list for uploads and healing
- be prepared to regenerate or heal URLs
- verify hashes when integrity matters

## UI Model

Do not make users stare at a blank screen while Blossom discovery or healing runs.

Good UI behavior:

- show upload progress as bytes stream
- render the current URL immediately if it still works
- heal broken URLs in the background
- update the view when a better or working URL is found

Blossom is still event-oriented product infrastructure. It should support progressive UX, not block it.

## Environment Model

The package uses web-style primitives:

- `File`
- `Blob`
- `fetch`
- `crypto.subtle`

In browsers that is natural.

In Node, you need Node 18+ style globals and often need to convert local filesystem inputs into `File` objects yourself.

This matters a lot for CLIs and server-side tooling.

## Practical Caveats

Real interoperability matters more than pretty docs.

Observed behavior against `https://blossom.primal.net`:

- upload works with a proper signer
- listing your own blobs may require auth
- delete can be slow enough that tools should use sensible timeouts and post-delete verification

Treat Blossom integrations as protocol work, not just convenience SDK work.

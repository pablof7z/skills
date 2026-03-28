# NDK Blossom Builder Workflows

## Basic Upload

```ts
import NDK from "@nostr-dev-kit/ndk";
import { NDKPrivateKeySigner } from "@nostr-dev-kit/ndk";
import { NDKBlossom, defaultSHA256Calculator } from "@nostr-dev-kit/blossom";

const signer = new NDKPrivateKeySigner("nsec1...");
const ndk = new NDK({ signer });
const blossom = new NDKBlossom(ndk, signer);

blossom.setSHA256Calculator(defaultSHA256Calculator);

const imeta = await blossom.upload(file, {
  server: "https://blossom.primal.net",
  sha256Calculator: defaultSHA256Calculator,
});
```

Use a known `server` when the product or CLI already knows exactly where it wants to upload.

## Turn the Upload Into a Nostr Tag

```ts
import { imetaTagToTag } from "@nostr-dev-kit/ndk/lib/utils/imeta";

const imetaTag = imetaTagToTag(imeta);

const event = new NDKEvent(ndk, {
  kind: 1,
  content: "check this out",
  tags: [imetaTag],
});

await event.publish();
```

This is the right way to carry uploaded media into nostr content.

## Publish a User's Blossom Server List

```ts
import { NDKBlossomList } from "@nostr-dev-kit/ndk";

await ndk.connect();

const list = new NDKBlossomList(ndk);
list.servers = [
  "https://blossom.primal.net",
  "https://cdn.example.com",
];

await list.publishReplaceable();
```

Use `publishReplaceable()` because `kind:10063` is replaceable state.

## Update an Existing Server List

```ts
const existing = await ndk.fetchEvent({ kinds: [10063], authors: [pubkey] });
const list = existing ? NDKBlossomList.from(existing) : new NDKBlossomList(ndk);

list.default = "https://blossom.primal.net";
list.addServer("https://cdn.example.com");

await list.publishReplaceable();
```

Prefer the wrapper class over hand-editing `server` tags.

## Heal a Broken URL

```ts
await ndk.connect();

const fixedUrl = await blossom.fixUrl(user, brokenUrl);
```

Use this when a URL no longer works but the author's server list may still point to valid copies of the same hash.

## Check Whether a Server Has a Blob

```ts
const exists = await blossom.checkServerForBlob(
  "https://blossom.primal.net",
  sha256
);
```

This is direct server work. It does not need relays.

## List a User's Blobs

```ts
await ndk.connect();

const blobs = await blossom.listBlobs(user);
```

Important caveat:

- some servers may require auth to list the active user's own blobs
- the signer may need to match the listed user

## Delete a Blob

```ts
await ndk.connect();

const ok = await blossom.deleteBlob(sha256);
```

This depends on the user's published server list. If the user's `kind:10063` event is missing or stale, deletion can fail even with a valid signer.

## Generate Optimized Media URLs

```ts
const optimizedUrl = await blossom.getOptimizedUrl(originalUrl, {
  width: 1024,
  format: "webp",
});
```

This is a read-only transformation on a known URL.

## Node CLI Pattern

In Node, convert filesystem inputs into `File` objects before uploading. Use Node 18+ globals and test under plain `node`, not only Bun.

The usual pattern is:

- read file bytes from disk
- construct a `File`
- upload with `defaultSHA256Calculator`
- print or persist the returned `imeta`

## Common Mistakes To Avoid

- Treating a single returned upload URL as the whole identity of the media
- Ignoring `kind:10063` and hardcoding only one media server forever
- Hand-rolling `kind:10063` tags instead of using `NDKBlossomList`
- Forgetting to provide or set a SHA256 calculator
- Assuming list operations never require auth
- Blocking UI while healing or while waiting on server-list discovery
- Publishing media references without converting the upload result into `imeta`

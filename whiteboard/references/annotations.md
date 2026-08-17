# Annotations (W3C Web Annotation)

Comments in a whiteboard session are stored as JSON files in the session's `comments/` directory, one file per comment or reply. Each file is a W3C Web Annotation (https://www.w3.org/TR/annotation-model/) so the anchors are standards-based and portable.

The viewer creates comment files via `POST /api/comments`; the agent writes reply files directly to `comments/`. Both the viewer and the agent watch this directory, so new files appear live everywhere.

## Top-level comment (a human asking about a span)

```json
{
  "@context": "http://www.w3.org/ns/anno.jsonld",
  "type": "Annotation",
  "id": "urn:uuid:7fc0547a-fdac-4d09-9bbc-2f76be85dcc5",
  "motivation": "commenting",
  "created": "2026-08-17T18:23:59.514Z",
  "creator": { "type": "Person", "name": "user" },
  "body": {
    "type": "TextualBody",
    "value": "why is this?",
    "format": "text/markdown",
    "language": "en"
  },
  "target": {
    "source": "deliverable.md",
    "version": "9d642b10b9c9",
    "selector": [
      {
        "type": "TextQuoteSelector",
        "exact": "How should versions be snapshotted?",
        "prefix": "\n- ",
        "suffix": "\n"
      },
      {
        "type": "TextPositionSelector",
        "start": 312,
        "end": 350
      }
    ]
  }
}
```

- `id` is a `urn:uuid:…`. Replies target this id.
- `target.version` is the sha256-first-12-hex of `deliverable.md` at the time the comment was made. The viewer snapshots that version to `versions/<version>.md`, so the exact anchored text can always be recovered even after later edits.
- `target.selector` carries both a `TextQuoteSelector` (robust to edits — re-anchored by searching the current document text) and a `TextPositionSelector` (character offsets in the document's text content, a fallback hint). The viewer re-anchors by quote first, then position.
- `body.format` is `text/markdown`; the viewer renders it sanitized.

## Reply (the agent answering, threaded under the comment)

```json
{
  "@context": "http://www.w3.org/ns/anno.jsonld",
  "type": "Annotation",
  "id": "urn:uuid:21b9c3a0-1d2e-4f5a-8b7c-9e0f1a2b3c4d",
  "motivation": "replying",
  "created": "2026-08-17T18:25:00.000Z",
  "creator": { "type": "Person", "name": "agent" },
  "body": {
    "type": "TextualBody",
    "value": "because snapshotting by content hash lets comments stay anchored to the exact text they were made against, even after later edits.",
    "format": "text/markdown",
    "language": "en",
    "inReplyTo": "urn:uuid:7fc0547a-fdac-4d09-9bbc-2f76be85dcc5"
  },
  "target": {
    "id": "urn:uuid:7fc0547a-fdac-4d09-9bbc-2f76be85dcc5",
    "type": "Annotation"
  }
}
```

A reply targets the **annotation it replies to** (`target.id` = the parent comment's `id`, `target.type: "Annotation"`), with `motivation: "replying"`. This is the standard W3C threading pattern. The viewer nests replies under their parent and sorts threads by document position.

## Agent reply procedure

When the comment watcher (`whiteboard/viewer/wait-for-comment.mjs`) exits with a new comment id:

1. Read the new comment file from `comments/` to see the question and the anchored span.
2. Answer it. If the answer changes the model, also edit `deliverable.md` (retroactively) and append to `notes.md`.
3. Write a reply file into `comments/` using the shape above — `creator.name: "agent"`, `motivation: "replying"`, `target.id` = the parent comment's `id`. The viewer's filesystem watch renders it live; no restart needed.
4. Relaunch the watcher for the next comment.

File naming: `<unix-ms>-<6-hex>.json`. The server names files this way for comments created via the API; the agent can use any unique `.json` name (e.g. `<unix-ms>-agent-reply.json`).

## Orphaned comments

If the deliverable is edited so a comment's `TextQuoteSelector.exact` no longer appears in the document, the viewer marks the thread orphaned and shows the original excerpt with the version it was made against (recoverable from `versions/<version>.md`). The comment is not lost. Re-anchoring is automatic once the quoted text reappears.
# Whiteboard Viewer

A localhost web viewer for a whiteboard session workspace. It renders the session's `deliverable.md` and lets a human add W3C Web Annotation comments anchored to spans of the document at a specific version. Comments and replies are JSON files in the session's `comments/` directory; the viewer watches the filesystem and re-renders live.

The companion agent watches the same `comments/` directory (see `wait-for-comment.mjs`) and writes reply annotation files, which appear live in the viewer.

## Layout

```text
viewer/
├── server.mjs            # Node HTTP + SSE server, fs watch, comment API
├── wait-for-comment.mjs  # CLI the agent runs: exits when a new human comment lands
├── index.html            # viewer UI shell
├── app.mjs               # browser client: render, selection, anchoring, sidebar, SSE
├── styles.css
└── vendor/               # marked + DOMPurify (vendored, no runtime network deps)
```

No build step. Requires Node 18+ (uses `node:http`, `fs.watch`, ES modules).

## Run

```bash
node server.mjs <session-dir> [--port 4318] [--open]
```

- Binds to `127.0.0.1` only (loopback).
- Watches `<session-dir>/deliverable.md`, `notes.md`, and `comments/`; pushes changes to the browser via SSE.
- Snapshots `deliverable.md` to `versions/<sha12>.md` on every change so anchored versions are recoverable.

## HTTP API

| Route | Method | Purpose |
|---|---|---|
| `/` | GET | viewer UI |
| `/api/session` | GET | manifest + current deliverable version |
| `/api/deliverable` | GET | `{ content, version }` |
| `/api/notes` | GET | `{ content }` |
| `/api/comments` | GET | `{ annotations: […] }` |
| `/api/comments` | POST | create a comment or reply; writes a W3C annotation file |
| `/api/manifest` | PATCH | update manifest fields (e.g. status) |
| `/api/events` | GET | SSE stream (`deliverable`, `notes`, `comments` events) |

## Comment watcher (agent-side)

```bash
node wait-for-comment.mjs <session-dir> [--timeout 0]
```

Baselines existing comments, then exits `0` (printing the new annotation's `urn:uuid:…` id) as soon as a new top-level human comment without an agent reply appears. `--timeout N` exits `2` (`idle`) after N seconds. The agent runs this as a background monitor wired to wake it on completion, then writes a reply annotation file and relaunches the watcher.

See `../references/annotations.md` for the W3C Web Annotation shapes.
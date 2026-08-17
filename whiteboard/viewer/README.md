# Whiteboard Viewer

A localhost web viewer for all whiteboard sessions under a root directory (default `~/whiteboard`). It serves an **explorer** (projects → sessions with unread badges) and a per-session view that renders `deliverable.md` and lets the human add W3C Web Annotation comments anchored to spans of the document at a specific version. Comments and replies are JSON files in each session's `comments/`; the viewer watches the filesystem and re-renders live.

The companion agent watches a session's `comments/` directory (see `wait-for-comment.mjs`) and writes reply annotation files, which appear live in the viewer and bump the session's unread badge until the human opens it.

## Layout

```text
viewer/
├── server.mjs            # Node HTTP + SSE server, root fs watch, session + explorer APIs
├── wait-for-comment.mjs  # CLI the agent runs: exits when a new human comment lands
├── lib/session.mjs       # session read/write + unread + list helpers
├── main.mjs              # client router (explorer vs session view)
├── explorer.mjs          # explorer client: sessions list with unread badges
├── viewer.mjs            # session client: render, selection, anchoring, sidebar, SSE
├── index.html            # shell
├── styles.css
└── vendor/               # marked + DOMPurify (vendored, no runtime network deps)
```

No build step. Requires Node 18+ (ES modules, `fs.watch` recursive).

## Run

```bash
node server.mjs [<root-dir>] [--port 4318] [--open]
```

- `<root-dir>` defaults to `~/whiteboard`. Sessions are `<root>/<project>/YYYY-MM-<slug>/`.
- Binds to `127.0.0.1` only (loopback).
- `GET /` → explorer. `GET /session/<project>/<slug>` → session view (SPA fallback).
- Watches the whole root; pushes explorer `sessions` events and per-session `refresh` events via SSE.
- Snapshots `deliverable.md` to `versions/<sha12>.md` on every read/change.

## HTTP API

| Route | Method | Purpose |
|---|---|---|
| `/api/sessions` | GET | list all sessions with name, status, comment count, unread, lastActivity |
| `/api/events` | GET | explorer SSE (`sessions` events) |
| `/api/session/<p>/<s>/session` | GET | manifest + current deliverable version |
| `/api/session/<p>/<s>/deliverable` | GET | `{ content, version }` |
| `/api/session/<p>/<s>/notes` | GET | `{ content }` |
| `/api/session/<p>/<s>/comments` | GET | `{ annotations: […] }` |
| `/api/session/<p>/<s>/comments` | POST | create a comment or reply (W3C annotation file) |
| `/api/session/<p>/<s>/seen` | POST | mark session seen (clears unread badge) |
| `/api/session/<p>/<s>/manifest` | PATCH | update manifest fields (e.g. status) |
| `/api/session/<p>/<s>/events` | GET | per-session SSE (`refresh` events) |

## Unread

Unread count = annotations whose `creator.name` is not `user` and whose `created` is after the session's `lastSeenAt` (stored in `.seen.json`). Opening a session view POSTs `/seen` and clears the badge. New agent replies bump it again until the human reopens.

## Comment watcher (agent-side)

```bash
node wait-for-comment.mjs <session-dir> [--timeout 0]
```

Baselines existing comments, then exits `0` (printing the new annotation's `urn:uuid:…` id) as soon as a new top-level human comment without an agent reply appears. `--timeout N` exits `2` (`idle`) after N seconds. The agent runs this as a background monitor wired to wake it on completion, then writes a reply annotation file and relaunches the watcher.

See `../references/annotations.md` for the W3C Web Annotation shapes.
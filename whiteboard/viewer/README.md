# Whiteboard Viewer

A localhost web viewer for all whiteboard sessions under a root directory (default `~/whiteboard`). It serves an **explorer** (projects → sessions with unread badges) and a per-session view that renders the **block document** (the fold over `changes/<rev>.json`) and lets the human add comments anchored to a block (optionally to an in-block span). The viewer watches the filesystem and re-renders live.

The companion agent detects new comments/chat via `wb listen` (run as a background monitor; see `../cli/main.mjs`) and replies through `wb change`, which appends a change file the viewer picks up live.

## Layout

```text
viewer/
├── server.mjs            # Node HTTP + SSE server, root fs watch, session + explorer APIs
├── lib/session.mjs       # session read/write (manifest, notes, chat, viewed) + list helpers
├── lib/blockdoc.mjs      # block-document API: fold read, comment/reply/resolve append-change
├── main.mjs              # client router (explorer vs session view)
├── explorer.mjs          # explorer client: sessions list with unread badges
├── blockview.mjs         # session client: block render, margin comments, diff, TOC, chat, SSE
├── comments.mjs          # shared quote-matching helpers (quoteMatch / quoteIndex)
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
- `GET /` → explorer. `GET /session/<project>/<slug>` → block session view (SPA fallback).
- Watches the whole root; pushes explorer `sessions` events and per-session `refresh` events via SSE.

## HTTP API

| Route | Method | Purpose |
|---|---|---|
| `/api/sessions` | GET | list all sessions with name, status, comment count, unread, lastActivity |
| `/api/events` | GET | explorer SSE (`sessions` events) |
| `/api/session/<p>/<s>/session` | GET | manifest + `viewedVersion` + resolved map |
| `/api/session/<p>/<s>/document` | GET | the folded block document (`blocks`, `comments`, `attachments`, `rev`, `hash`) |
| `/api/session/<p>/<s>/revisions` | GET | revision list (rev, at, title, by, op counts) |
| `/api/session/<p>/<s>/revisions/<rev>` | GET | document state at a rev (for diffing) |
| `/api/session/<p>/<s>/jump` | POST | focus the iTerm pane that authored a rev (provenance) |
| `/api/session/<p>/<s>/notes` | GET | `{ content }` (notes.md) |
| `/api/session/<p>/<s>/comments` | GET | `{ comments: […] }` |
| `/api/session/<p>/<s>/comments` | POST | create a comment (`{block,text,selector,creator}`) or reply (`{replyTo,text,creator}`) — appends a change |
| `/api/session/<p>/<s>/resolved` | GET / POST | read/toggle the resolved map |
| `/api/session/<p>/<s>/viewed` | GET / POST | read/mark the reviewed rev (diff "Done" button) |
| `/api/session/<p>/<s>/chat` | GET / POST | file-queue chat (human posts; agent writes reply files) |
| `/api/session/<p>/<s>/manifest` | PATCH | update manifest fields (e.g. status) |
| `/api/session/<p>/<s>/events` | GET | per-session SSE (`refresh` events) |

## Unread

Unread count = actionable user comments (unresolved, no agent reply) + unanswered user chat messages, computed from the folded document and `chat/`. The explorer badge and the pi extension footer both use this.

## Comment detection (agent-side)

```bash
wb listen [--session <project>/<slug>] [--timeout 0]
```

Baselines existing actionable items, then prints one JSONL event (`{"kind":"comment"|"chat","id","block","session","excerpt"}`) and exits `0` as soon as a NEW actionable item appears. `--timeout N` exits `2` with `{"kind":"idle"}` after N seconds. Run it as a background monitor; its completion wakes the agent, which replies via `wb change` and relaunches the monitor. Under pi, the extension wakes the agent natively (attributed whiteboard message) instead.
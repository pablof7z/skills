# Whiteboard under pi (pi-whiteboard extension)

Brief how-to for using whiteboard inside a pi harness with the **pi-whiteboard extension** loaded. If the extension isn't loaded, use the portable CLI instead — see [cli-ops.md](cli-ops.md).

## What the extension does for you

- **Viewer auto-managed.** A localhost web viewer (`http://127.0.0.1:4318/`) is spawned-if-down on `session_start` and kept alive across `/new`, `/resume`, `/reload`. You never launch or restart it. Tell the human the root URL and the direct session link `http://127.0.0.1:4318/session/<project>/<slug>`.
- **Current session auto-tracked.** The extension pins the current whiteboard session to the one owned by this pi session (`manifest.owner === getSessionId()`), so `wb` CLI calls and the `wb_*` tools resolve it without you passing a session. `wb new`/`wb use` (or `wb_new`/`wb_use`) stamp `manifest.owner` so the extension picks them up on the next `session_start`.
- **Attributed wake.** You do **not** run `wb listen`. The extension watches `~/whiteboard` and, when a new actionable human annotation (a `question`/`warning`/`objection`) or chat lands in a session you own, wakes you with a `[whiteboard]` message that **triggers a turn** (rendered as a whiteboard-attributed message, not user text). `note` threads and tags do **not** wake (a note is a side comment; a tag is a status marker).
- **Footer badge.** `📓 N unread` counts your actionable threads + unanswered chat.

## The whiteboard tools (preferred over the CLI)

Twelve tools, exposed via pi's **lazy/active** pattern. A fresh agent sees only the two **loaders**; calling either unlocks the rest (pi surfaces the newly-available tool names on the tool result, so they appear on the next request). Owning agents — a session owned by this pi session — get the full set at `session_start`, so an attributed wake can be answered immediately without listing first.

- **Loaders (always active for a fresh agent):**
  - `wb_new { slug }` — create a session; unlocks the doc + mutation tools.
  - `wb_list { json? }` — list sessions for this project; also unlocks.
- **Unlocked by `wb_new`/`wb_list`/`wb_use`:**
  - `wb_use { slug }` — switch to (claim) an existing session.
  - `wb_read { format?: "md"|"json", path?, block? }` — project the doc. `md` (default) = block bodies + an action-section (`## Open threads` — unresolved `id · path · block · kind · author` + replies; `## Tags` — active status tags; `## Meta` — rev/updatedAt). With no `path` and multiple files, emits a `## 📄 <path>` header per file (the file tree). `json` = full structured doc (blocks + annotations + attachments + rev/hash). `path` scopes to one file; `block` (with `path`) to one block.
  - `wb_diff { before, after, path? }` — return the unified artifact diff between two revisions. Each revision is `0`, an existing number, or `"current"`; `path` limits a multi-file document. This is read-only and excludes attachments/tags.
  - `wb_note { text, by? }` — append a timestamped line to `notes.md`.
  - **Artifact mutation — the `wb_change_` family (start → ops → finish).** `wb_change` is for **block edits only** (the artifact). Annotations are NOT staged.
    - `wb_change_start { title, summary?, by? }` — open a staging transaction (one at a time).
    - `wb_change_block { op, path?, … }` — stage a block-level op. `op` ∈ `add|edit|move|rename|remove`. `path` is the file the block belongs to (default `default.md`); block names are unique **within a path**.

      | op | params |
      | --- | --- |
      | `add` | `name` (new block), `text`, `before?`/`after?` (anchor) |
      | `edit` | `block`, `text` (full new md) **or** `diff` (unified diff, applied in-process to the WIP block) |
      | `move` | `block`, `before?`/`after?` |
      | `rename` | `block` (old), `name` (new) |
      | `remove` | `block` \| `names[]` |

    - `wb_change_finish { op: "commit"|"abandon" }` — commit (send) or abandon (discard) the open transaction.
  - **Annotations — direct (NOT staged).** One command each, like `wb_note`.
    - `wb_attach { op, … }` — replyable threads anchored to a span. `op` ∈ `attach|reply|resolve|reopen|list`. `on` is the anchor text within the block (**required** for `attach`). `kind` (attach only) ∈ `question|warning|objection|note`.

      | op | params |
      | --- | --- |
      | `attach` | `block`, `on`, `kind`, `content`, `by?`, `path?` |
      | `reply` | `id`, `content`, `by?` |
      | `resolve` / `reopen` | `id` |
      | `list` | `block?`, `path?`, `open?` |

    - `wb_tag { op, … }` — short status tags anchored to a span. `op` ∈ `set|clear|list`. `on` required for `set`/`clear`. `kind` ∈ `unverified|superseded|needs-attention|decided`. `set` is idempotent (a second `set` of the same tag on the same span is a no-op).

      | op | params |
      | --- | --- |
      | `set` | `block`, `on`, `kind`, `content?`, `by?`, `path?` |
      | `clear` | `block`, `on`, `kind`, `by?`, `path?` |
      | `list` | `block?`, `path?` |

There is no `session` param — the tools use the tracked current session (set by `wb_new`/`wb_use`/`session_start`). (`wb change status` to peek staged ops is CLI-only; you staged the ops yourself.)

## Multi-file sessions (paths)

A session holds **one block document**, but each block carries a `path` (default `default.md`) — so the document can span multiple files. A file = its blocks (filtered by path, in document order). Block identity is `(path, name)`; names are unique **within a path**, so two files can both have a block named `intro`. Everything else (staging, annotations, notes, the wake path) is unchanged — `path` is just an extra optional param that defaults to `default.md`.

- `wb_change_block { op: "add", path: "references/pi.md", name: "examples", text: … }` — add a block to a specific file.
- `wb_read { path: "references/pi.md" }` — read one file; `wb_read {}` — read the whole tree (a `## 📄 <path>` header per file).
- Annotations anchor to a block (which carries its path) — so `wb_attach { op: "attach", path: "references/pi.md", block: "intro", on: "the quote", kind: "question", content: … }` lands on that file's `intro`.
- Existing sessions (blocks with no path) all render as one file `default.md` — fully backward compatible.
- The webui shows the file paths in the TOC sidebar (a file tree when there are multiple files).
- The CLI mirrors this: `wb change add … --path references/pi.md`, `wb read --md --path references/pi.md`, and `wb new --from <md-file> --path <p>` imports a file's sections into that path.

Seed example:
```
wb_new { slug: "2026-08-feature-x" }
wb_change_start { title: "seed session" }
wb_change_block { op: "add", name: "goal", text: "# Goal\n…" }
wb_change_block { op: "add", name: "constraints", text: "# Constraints\n- …" }
wb_change_finish { op: "commit" }
```

## Replying to a wake

When you receive a `[whiteboard]` annotation wake, it looks like:
```
Annotation (<kind>) on block "<block>" in <project>/<slug> (id <id>):
> <highlighted span>

User's message:
<full text>
```
Reply directly (no staging):
```
wb_attach { op: "reply", id: "<id>", content: "your answer" }
wb_attach { op: "resolve", id: "<id>" }   # if settled
```
Every annotation is anchored, so the `> <highlighted span>` line is always present. Both the span and the text arrive in full, untruncated.

If the answer changes the document, stage those `edit`/`add` ops via `wb_change_block` in a `wb_change_start`…`wb_change_finish` transaction (separate from the annotation reply, which is already committed).

For a `[whiteboard] New chat …` wake, reply by writing an agent chat message file into the session's `chat/` dir (`{id, role:"agent", text, created}`); there is no chat op. Update the document via the tools if the message changes the model. Do not answer an annotation/chat only in the host conversation — the human is reviewing in the viewer.

## `/wb` command (human escape hatch)

`/wb` prints status (current `WB_SESSION` + viewer URL). `/wb <args…>` runs the `wb` CLI and shows output — useful for things the tools don't cover (e.g. `wb list`, `wb read --json`, `wb change status`, `wb attach list`). Quoted bodies work (`/wb attach goal --on "quote" --kind question --content "some text"`).

See [cli-ops.md](cli-ops.md) for the full CLI surface.

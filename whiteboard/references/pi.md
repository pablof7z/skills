# Whiteboard under pi (pi-whiteboard extension)

Brief how-to for using whiteboard inside a pi harness with the **pi-whiteboard extension** loaded. If the extension isn't loaded, use the portable CLI instead — see [cli-ops.md](cli-ops.md).

## What the extension does for you

- **Viewer auto-managed.** A localhost web viewer (`http://127.0.0.1:4318/`) is spawned-if-down on `session_start` and kept alive across `/new`, `/resume`, `/reload`. You never launch or restart it. Tell the human the root URL and the direct session link `http://127.0.0.1:4318/session/<project>/<slug>`.
- **`WB_SESSION` auto-resolved.** The extension pins `WB_SESSION` to the whiteboard session owned by this pi session (`manifest.owner === getSessionId()`), so `wb` CLI calls and the `whiteboard` tool resolve it without `--session`. `wb new`/`wb use` stamp `manifest.owner` so the extension picks them up on the next `session_start`.
- **Attributed wake.** You do **not** run `wb listen`. The extension watches `~/whiteboard` and, when a new actionable human comment or chat lands in a session you own, wakes you with a `[whiteboard]` message that **triggers a turn** (rendered as a whiteboard-attributed message, not user text).
- **Footer badge.** `📓 N unread` counts your actionable comments + unanswered chat.

## The `whiteboard` tool (preferred over the CLI)

One tool, three actions. Use it instead of shelling out to `wb`:

- **`read`** — project the block document. `format: "tagged"|"md"|"json"` (default `tagged`).
- **`change`** — the staging transaction:
  - `sub: "start"` with `title` (and optional `summary`) — open a change.
  - `sub: "send"` / `"discard"` / `"status"` — commit / abort / peek.
  - `sub:` one of `edit|add|move|rename|remove|comment|reply|resolve|unresolve|flag|attention|amend|detach` — stage one op. Fields map to the CLI: `block`, `name`, `names`, `before`/`after`, `text` (or `diff` for `edit`), `exact` (selector quote), `threadId`, `flag`, `clear`, `by`.
- **`note`** — append to `notes.md` (`text`).

`session` is optional (defaults to `WB_SESSION` / the owners map). All mutations are staged then committed with `sub: "send"`.

Seed example:
```
whiteboard { action: "change", sub: "start", title: "seed session" }
whiteboard { action: "change", sub: "add", name: "goal", text: "# Goal\n…" }
whiteboard { action: "change", sub: "add", name: "constraints", text: "# Constraints\n- …" }
whiteboard { action: "change", sub: "send" }
```

## Replying to a wake

When you receive `[whiteboard] New comment on block "<block>" … (id <id>)`:
```
whiteboard { action: "change", sub: "start", title: "reply to <id>" }
whiteboard { action: "change", sub: "reply", threadId: "<id>", text: "your answer" }
whiteboard { action: "change", sub: "resolve", threadId: "<id>" }   # if settled
whiteboard { action: "change", sub: "send" }
```
If the answer changes the document, stage those `edit`/`add` ops in the same transaction before `send`.

For `[whiteboard] New chat …`, reply by writing an agent chat message file into the session's `chat/` dir (`{id, role:"agent", text, created}`); there is no chat op. Update the document via the tool if the message changes the model. Do not answer a comment/chat only in the host conversation — the human is reviewing in the viewer.

## `/wb` command (human escape hatch)

`/wb` prints status (current `WB_SESSION` + viewer URL). `/wb <args…>` runs the `wb` CLI and shows output — useful for things the tool doesn't cover (e.g. `wb list`, `wb read --json`). Quoted bodies work (`/wb change comment goal "some text"`).

See [cli-ops.md](cli-ops.md) for the full CLI surface.
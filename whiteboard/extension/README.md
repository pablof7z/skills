# Whiteboard pi extension

A pi (pi-coding-agent) extension that accelerates the whiteboard skill when running under pi. The skill stays portable; this extension is the pi-native accelerator.

## What it does

### Viewer lifecycle
The viewer is a persistent, self-healing daemon. On `session_start` it's spawned-if-down (`node ../viewer/server.mjs ~/whiteboard`, detached so it survives pi restarts/reloads). A 10s heartbeat re-checks and respawns it if it crashes or is killed. The extension **never kills the viewer** — it's kept across `/new`, `/resume`, `/reload`, and even after pi quits. Stop it manually with `pkill -f viewer/server.mjs`.

### `WB_SESSION` resolution
On `session_start` the extension resolves the whiteboard session owned by THIS pi session (`manifest.owner === getSessionId()`; `myProject` = cwd basename, or `WHITEBOARD_PROJECT`) and sets `process.env.WB_SESSION = "<project>/<slug>"` so `wb` CLI commands and the `whiteboard` tool resolve it. Owner-scoped — no global current file and no most-recently-modified fallback (both would let concurrent agents silently pin to each other's sessions). If this agent owns no session yet, `WB_SESSION` stays unset and the agent passes `--session`. `wb new`/`wb use` stamp `manifest.owner` via `WB_OWNER` so the extension picks them up on the next `session_start`.

### Attributed wake (whiteboard messages, not user messages)
The extension watches `~/whiteboard` and, on a change to a session it owns, finds comments that are **new since the last-seen comment set** AND actionable (`author === "user"`, `resolved === false`, no reply in `replies[]` with `author === "agent"`), plus unanswered user chat messages. It baselines existing ids per session on `session_start` so existing items don't wake. It wakes the agent via:

```ts
pi.sendMessage({ customType: "whiteboard", content, display: true },
               { triggerTurn: true, deliverAs: "followUp" });
```

A `registerMessageRenderer("whiteboard", …)` renders these with a `[whiteboard]` tag instead of as user-typed text. The wake triggers a turn. Only sessions whose project === `myProject` AND `manifest.owner === this pi session` wake this pi session.

### Footer status
`ctx.ui.setStatus("whiteboard", "📓 N unread")`. Unread = actionable unresolved `user` comments + unanswered user chat, total across `myProject`'s sessions owned by this agent.

### The `whiteboard` tool
One tool (`whiteboard`) registered via `pi.registerTool`, callable directly by the LLM — no CLI round-trip. Three actions:
- `read` — project the block document (`format: "tagged"|"md"|"json"`).
- `change` — open/send/discard a staging transaction, or stage one op (`sub`: `start|send|discard|status|edit|add|move|rename|remove|comment|reply|resolve|unresolve|flag|attention|amend|detach`).
- `note` — append to `notes.md`.

Session resolves from the `session` arg, else `WB_SESSION`, else the per-agent owners map. See `tool.mjs`.

### `/wb` command
- `/wb` (no args) prints status: current `WB_SESSION` and viewer URL, and ensures the viewer is up.
- `/wb <args…>` dispatches to `node <skill-dir>/whiteboard/cli/main.mjs <args…>` and prints stdout/stderr to the user (args are shell-tokenized, so quoted bodies work). Scoped to `WB_SESSION` / `--session` as the CLI resolves them. Human escape hatch; the agent path is the `whiteboard` tool.

## Install

The extension is auto-discovered when linked into pi's global extensions dir:

```bash
ln -sfn <repo>/whiteboard/extension ~/.pi/agent/extensions/whiteboard
```

Then `/reload` or start a new pi session. Verify with `pi -p "ok"` (loads with no error).

## Modules
- `index.ts` — factory: viewer lifecycle, `session_start`/`session_shutdown`, the recursive watcher + attributed wake dispatch, footer status, `/wb` command, tool + renderer registration.
- `tool.mjs` — the `whiteboard` tool (schema + execute); wraps `cli/staging.mjs` + `cli/doc.mjs` + `cli/blocks.mjs`. typebox is lazy-required so the module loads under bare-node tests.
- `scan.mjs` — session listing + unread helpers; re-exports the pure actionable-item helpers from `cli/scan.mjs`.
- Owner-scoped `WB_SESSION` resolution is inlined in `index.ts` (`resolveOwnedSession`: `manifest.owner === getSessionId()` → unset if none owned; inlined so it survives `/reload`'s transitive-module caching).

## Test

```bash
node --experimental-strip-types extension/test-blocks.ts      # attributed wake + scoping
node --experimental-strip-types extension/test-ownership.ts   # only the owning agent wakes
node extension/wb-diff.test.mjs                               # wb diff CLI + Pi tool
```

`test-blocks.ts` verifies: (1) a session with a new actionable `user` comment produces a `sendMessage` wake; (2) a session in a different project does NOT wake. `test-ownership.ts` verifies only the agent that owns the session wakes.

# Whiteboard pi extension

A pi (pi-coding-agent) extension that accelerates the whiteboard skill when running under pi. The skill stays portable; this extension is the optional pi-native accelerator.

## What it does

### Viewer lifecycle (unchanged)
The viewer is a persistent, self-healing daemon. On `session_start` it's spawned-if-down (`node ../viewer/server.mjs ~/whiteboard`, detached so it survives pi restarts/reloads). A 10s heartbeat re-checks and respawns it if it crashes or is killed. The extension **never kills the viewer** — it's kept across `/new`, `/resume`, `/reload`, and even after pi quits. Stop it manually with `pkill -f viewer/server.mjs`.

### Block document model support
The whiteboard skill now uses a block-based `document.json` (not `deliverable.md`) as the source of truth, with comments living **inside** `document.json`. This extension supports both models without regressing legacy sessions:

- **`WB_SESSION` resolution.** On `session_start` the extension resolves the whiteboard session owned by THIS pi session (`manifest.owner === getSessionId()`; `myProject` = cwd basename, or `WHITEBOARD_PROJECT`) and sets `process.env.WB_SESSION = "<project>/<slug>"` so `wb` CLI commands resolve it. Owner-scoped — no global `~/.wb/current` and no most-recently-modified fallback (both would let concurrent agents silently pin to each other's sessions). If this agent owns no session yet, WB_SESSION stays unset and the agent passes `--session`. `wb new`/`wb use` stamp `manifest.owner` via `WB_OWNER` so the extension picks them up on the next `session_start`.
- **Block-doc wake (scoped to this session's project).** A session is a block-doc session if `document.json` exists in its dir. The extension watches `~/whiteboard` and, on a `document.json` change, loads it and finds comments that are **new since the last-seen comment set** AND actionable (`author === "user"`, `resolved === false`, no reply in `replies[]` with `author === "agent"`). It baselines the existing comment ids per session on `session_start` so existing items don't wake. It wakes the agent via `pi.sendUserMessage(prompt, { deliverAs: "followUp" })` with:
  ```
  [whiteboard] New comment on block "<block>" in <project>/<slug>: "<body excerpt>" (id <comment-id>). Reply via `wb change`: `wb change "Reply to <id>"` → `wb change reply <comment-id> "<text>"` → `wb change resolve <comment-id>` → `wb change send`.
  ```
  Only sessions whose project === `myProject` wake this pi session.
- **Legacy wake (unchanged path).** Sessions without `document.json` still use the `comments/` W3C-annotation + `chat/` scan, so existing sessions don't regress.

### Footer status
`ctx.ui.setStatus("whiteboard", "📓 N unread")`. For block-doc sessions, unread = actionable unresolved `user` comments in `document.json`; for legacy sessions, the existing resolved/unread mechanism. Total across `myProject`'s sessions.

### `/wb` command
- `/wb` (no args) prints status: current `WB_SESSION` and viewer URL, and ensures the viewer is up.
- `/wb <args…>` dispatches to `node <skill-dir>/whiteboard/cli/main.mjs <args…>` and prints stdout/stderr to the user (args are shell-tokenized, so quoted bodies like `wb comment goal "some text"` work). Scoped to `WB_SESSION` / `--session` as the CLI resolves them.

## Install

The extension is auto-discovered when linked into pi's global extensions dir:

```bash
ln -sfn <repo>/whiteboard/extension ~/.pi/agent/extensions/whiteboard
```

Then `/reload` or start a new pi session. Verify with `pi -p "ok"` (loads with no error).

## Modules
- `index.ts` — factory: viewer lifecycle, `session_start`/`session_shutdown`, the recursive watcher + wake dispatch, footer status, `/wb` command.
- `scan.mjs` — session listing + actionable-item + unread helpers for both the block-doc (`document.json`) and legacy (`comments/` + `chat/`) models.
- Owner-scoped `WB_SESSION` resolution is inlined in `index.ts` (`resolveOwnedSession`: `manifest.owner === getSessionId()` → unset if none owned; inlined so it survives `/reload`'s transitive-module caching).

## Test

```bash
node --experimental-strip-types extension/test-wake.ts     # legacy chat wake
node --experimental-strip-types extension/test-blocks.ts    # block-doc wake + scoping
```

`test-blocks.ts` verifies: (1) a block-doc session with a new actionable `user` comment in `document.json` produces a wake; (2) `document.json` with only `agent`/resolved comments does NOT wake; (3) a session in a different project does NOT wake.

## Deferred (next slices)

- Typed `whiteboard_*` tools (`update_deliverable`, `append_notes`, `reply_comment`) — now mostly covered by the `/wb` CLI dispatch.
- `before_agent_start` system-prompt override so the agent prefers `wb` over bash recipes.
- `resources_discover` to register the whiteboard skill path.
- Active-session persistence (`pi.appendEntry`) so wake targets the session bound to this pi session.
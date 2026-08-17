# Whiteboard pi extension

A pi (pi-coding-agent) extension that accelerates the whiteboard skill when running under pi. The skill stays portable; this extension is the optional pi-native accelerator.

## What it does (v1)

- **Viewer lifecycle.** The viewer is a persistent, self-healing daemon. On `session_start` it's spawned-if-down (`node ../viewer/server.mjs ~/whiteboard`, detached so it survives pi restarts/reloads). A 10s heartbeat re-checks and respawns it if it crashes or is killed. The extension **never kills the viewer** — it's kept across `/new`, `/resume`, `/reload`, and even after pi quits. Stop it manually with `pkill -f viewer/server.mjs`.
- **Native comment/chat wake (scoped to this session's project).** `fs.watch`es `~/whiteboard`; on a new actionable item **in this pi session's own project** (whiteboard `project` = cwd basename, overridable via `WHITEBOARD_PROJECT`) — a top-level human comment with no agent reply, or a human chat message with no agent reply after — calls `pi.sendUserMessage(prompt, { deliverAs: "followUp" })` to wake the agent in the live pi session. Baselines existing items on `session_start` so only new ones wake the agent. Other projects never wake this session (an `nmp` pi session isn't woken for a `skills` comment and vice-versa).
- **Footer status.** `ctx.ui.setStatus("whiteboard", "📓 N unread")` with total unread across sessions.
- **`/wb` command.** Opens the viewer in the browser.

## Install

The extension is auto-discovered when linked into pi's global extensions dir:

```bash
ln -sfn <repo>/whiteboard/extension ~/.pi/agent/extensions/whiteboard
```

Then `/reload` or start a new pi session. Verify with `pi -p "ok"` (loads with no error).

## Test

```bash
node --experimental-strip-types extension/test-wake.ts
```

Uses a mock `pi` to verify a new human chat message triggers `sendUserMessage`.

## Deferred (next slices)

- Typed `whiteboard_*` tools (`update_deliverable`, `append_notes`, `reply_comment`).
- `before_agent_start` system-prompt override so the agent prefers the tools over bash recipes (the SKILL.md conditional note covers v1).
- `resources_discover` to register the whiteboard skill path.
- Active-session persistence (`pi.appendEntry`) so wake targets the session bound to this pi session.
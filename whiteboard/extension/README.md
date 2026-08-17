# Whiteboard pi extension

A pi (pi-coding-agent) extension that accelerates the whiteboard skill when running under pi. The skill stays portable; this extension is the optional pi-native accelerator.

## What it does (v1)

- **Viewer lifecycle.** On `session_start`, ensures the whiteboard viewer server is running on `127.0.0.1:4318` (health-checks; spawns `node ../viewer/server.mjs ~/whiteboard` only if not already up). Kills the spawned viewer on `session_shutdown` only when pi actually quits (`reason: "quit"`), so it survives `/new`, `/resume`, `/reload`.
- **Native comment/chat wake.** `fs.watch`es `~/whiteboard`; on a new actionable item (a top-level human comment with no agent reply, or a human chat message with no agent reply after), calls `pi.sendUserMessage(prompt, { deliverAs: "followUp" })` to wake the agent in the live pi session. Baselines existing items on `session_start` so only new ones wake the agent.
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
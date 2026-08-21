# Whiteboard MCP server

Streamable HTTP MCP server for Whiteboard. It binds localhost by default and
uses an explicit `session_id` (`"project/slug"`) for every session-scoped tool.

## Run

```sh
cd whiteboard/mcp
npm install
node server.mjs
```

Use the printed four-character pairing code as the bearer token for
`http://127.0.0.1:4319/mcp`. The pairing code is a local-development auth seam;
OAuth discovery routes exist, but authorization-code/token exchange is not yet
configured.

## Tools

`wb_new`, `wb_list`, `wb_read`, `wb_diff`, `wb_note`, `wb_change_start`,
`wb_change_block`, `wb_change_finish`, `wb_attach`, and `wb_tag`.

`wb_diff` is read-only. Give it `session_id`, `before`, `after`, and optionally
`path`; revisions are `0`, an existing revision, or `"current"`. It returns the
same unified artifact diff as `wb diff` and the Pi `wb_diff` tool.

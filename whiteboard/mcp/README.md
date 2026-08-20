# whiteboard MCP server (WIP skeleton)

A standalone MCP server exposing the whiteboard operations over Streamable
HTTP, as a thin in-process layer over `../cli/*.mjs` — the same primitives
`../extension/tool.mjs` wires for the pi harness, but reachable by any MCP
client over HTTP instead of only inside pi.

**Status: skeleton.** The transport, tool surface, and pairing-code auth
gate are wired and start correctly; several seams are intentionally stubbed
(see TODOs below). Not yet reviewed for production use.

## Run

```
cd mcp && npm install
WHITEBOARD_MCP_PORT=4319 node server.mjs
```

Binds `127.0.0.1:4319` by default (`4318` is the whiteboard viewer — do not
collide). Prints the bound URL and a 4-character pairing code on startup;
authenticate requests to `/mcp` with `Authorization: Bearer <code>`.

## Transport

Streamable HTTP (not stdio), via `@modelcontextprotocol/server` 2.0.0
(`createMcpHandler`) + `@modelcontextprotocol/node` 2.0.0 (`toNodeHandler`,
localhost DNS-rebinding guards) over plain `node:http` — no Express. A single
`POST /mcp` endpoint; `legacy: 'stateless'` (the SDK default) serves both
modern (2026-07-28) and legacy `initialize`-era clients (current Claude
Code/Desktop), each request answered by a fresh per-request `McpServer`
instance. There is no protocol-level session — every tool takes an explicit
`session_id` (`"project/slug"`) argument instead (see `tools.mjs`); all
cross-call state lives on disk via `../cli/store.mjs` (`.staging.json`,
`changes/`, `notes.md`), which already serializes concurrent writers.

## Auth

Bearer = the pairing code printed at startup (`auth.mjs`'s `verifier`,
called via the SDK's `verifyBearerToken`/`bearerAuthChallengeResponse`). This
is a placeholder for real OAuth 2.1: `/.well-known/oauth-protected-resource`
and `/.well-known/oauth-authorization-server` are served for real (pointing
at this server's own `/authorize` + `/token`); `/authorize` and `/token`
themselves return `501` with a `TODO(mcp-http-auth):` comment describing the
real PKCE + authorization-code flow. Grep `TODO(mcp-http-auth):` for every
seam a real Authorization Server needs to replace.

## Tools

`wb_new`, `wb_list`, `wb_read`, `wb_note`, `wb_change_start`,
`wb_change_block`, `wb_change_finish`, `wb_attach`, `wb_tag` — see
`tools.mjs` for schemas. All nine are fully wired to `../cli/*.mjs`; none are
stubs.

## Resources

One template, `whiteboard://session/{project}/{slug}`, listing the current
project's sessions and reading a session's projected doc (`resources.mjs`).
Deliberately minimal — no per-file/per-block resource shapes yet.

## Open TODOs

- **Auth**: full OAuth 2.1 (`/authorize`, `/token`, PKCE, RFC 8707
  `resource=` binding) — see `TODO(mcp-http-auth):` markers in `auth.mjs` and
  `server.mjs`.
- **Network bind**: `WHITEBOARD_MCP_HOST` env exists but only localhost is
  exercised; a `--host`/`0.0.0.0` path needs its own DNS-rebinding story.
- **Wake notifications**: `wb listen` / actionable-item wake-ups are not
  wired over MCP. The SDK's `handler.notify`/`handler.bus` (for pushing
  `subscriptions/listen` events) is the intended mechanism — not used yet.
- **Error mapping**: every tool-handler exception currently maps to
  `{ isError: true, content: [{type:"text", text: error.message}] }`
  uniformly; no per-error-type JSON-RPC vs. tool-error distinction yet.

## Migration note

`@modelcontextprotocol/server` 2.x (2026-07-28 spec) is what this skeleton
targets, chosen over the older 1.x `@modelcontextprotocol/sdk` line because
its auth primitives (`verifyBearerToken`, `requireBearerAuth`,
`oauthMetadataResponse`) and per-request-factory HTTP model fit a
stateless-across-requests, disk-backed server naturally.

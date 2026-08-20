#!/usr/bin/env node
// server.mjs — whiteboard MCP server (skeleton). Streamable HTTP over plain
// node:http, bound to 127.0.0.1. See README.md for status + TODOs.
//
// SDK: @modelcontextprotocol/server 2.0.0 (createMcpHandler, McpServer) +
// @modelcontextprotocol/node 2.0.0 (toNodeHandler, toWebRequest, localhost
// DNS-rebinding guards). The handler's factory runs ONCE PER HTTP REQUEST — a
// fresh McpServer per request, nothing held between requests — so all
// cross-call state lives on disk via ../cli/store.mjs (matches the 2026
// "Stateful Tools" pattern: session_id is an explicit tool argument, not a
// protocol-level or in-memory session — see tools.mjs).
//
// Auth: bearer = the printed pairing code (see auth.mjs) — a placeholder for
// the real OAuth 2.1 resource-server flow. TODO(mcp-http-auth) markers below
// and in auth.mjs mark where the real Authorization Server plugs in.

import http from "node:http";
import { createMcpHandler, McpServer, verifyBearerToken, bearerAuthChallengeResponse } from "@modelcontextprotocol/server";
import { toNodeHandler, toWebRequest, localhostHostValidation, localhostOriginValidation } from "@modelcontextprotocol/node";
import { registerTools } from "./tools.mjs";
import { registerResources } from "./resources.mjs";
import { initPairingCode, verifier, handleWellKnown, handleAuthorizeStub, handleTokenStub } from "./auth.mjs";

const HOST = process.env.WHITEBOARD_MCP_HOST || "127.0.0.1"; // TODO: --host flag for 0.0.0.0 (network bind)
const PORT = Number(process.env.WHITEBOARD_MCP_PORT || "4319"); // 4318 is the whiteboard viewer — do not collide
const SERVER_URL = new URL(`http://${HOST}:${PORT}/mcp`);

function buildServer(_ctx) {
  const server = new McpServer({ name: "whiteboard-mcp", version: "0.1.0" });
  registerTools(server, _ctx);
  registerResources(server, _ctx);
  return server;
}

// legacy:'stateless' is createMcpHandler's default; spelled out so it's clear
// both eras are served: modern 2026-07-28 clients AND pre-envelope `initialize`
// clients (current Claude Code/Desktop) get a fresh per-request instance.
// https://ts.sdk.modelcontextprotocol.io/v2/serving/legacy-clients.html
const handler = createMcpHandler(buildServer, { legacy: "stateless" });
const nodeHandler = toNodeHandler(handler);

const validateHost = localhostHostValidation();
const validateOrigin = localhostOriginValidation();

async function writeWebResponse(res, webRes) {
  const headers = {};
  for (const [k, v] of webRes.headers) headers[k] = v;
  const body = await webRes.text();
  res.writeHead(webRes.status, headers);
  res.end(body);
}

const httpServer = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || `${HOST}:${PORT}`}`);

  // TODO(mcp-http-auth): these three routes are the real OAuth 2.1 seam —
  // well-known metadata is served for real (auth.mjs), /authorize + /token
  // are stubbed (501) until a real Authorization Server exists.
  if (url.pathname.startsWith("/.well-known/oauth-")) {
    const webReq = await toWebRequest(req);
    const webRes = await handleWellKnown(webReq, SERVER_URL);
    if (webRes) return writeWebResponse(res, webRes);
    res.writeHead(404); return res.end();
  }
  if (url.pathname === "/authorize") return handleAuthorizeStub(res);
  if (url.pathname === "/token") return handleTokenStub(res);

  if (url.pathname !== "/mcp") { res.writeHead(404); return res.end(); }
  if (!validateHost(req, res) || !validateOrigin(req, res)) return; // DNS-rebinding guards already answered the request

  let authInfo;
  try {
    authInfo = await verifyBearerToken(req.headers.authorization, { verifier, requiredScopes: [] });
  } catch (e) {
    return writeWebResponse(res, bearerAuthChallengeResponse(e));
  }
  req.auth = authInfo; // pass-through: toNodeHandler forwards req.auth as authInfo into the factory + tool ctx.http.authInfo
  nodeHandler(req, res);
});

const code = initPairingCode();
httpServer.listen(PORT, HOST, () => {
  console.log(`whiteboard-mcp listening on http://${HOST}:${PORT}/mcp`);
  console.log(`pairing code: ${code}  (Authorization: Bearer ${code})`);
});

process.on("SIGINT", async () => {
  await handler.close();
  httpServer.close(() => process.exit(0));
});

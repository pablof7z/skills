#!/usr/bin/env node
// Streamable-HTTP Whiteboard MCP server. Disk-backed Whiteboard session state
// is explicit in every tool's session_id; the protocol transport is stateless.

import http from "node:http";
import { createMcpHandler, McpServer, verifyBearerToken, bearerAuthChallengeResponse } from "@modelcontextprotocol/server";
import { toNodeHandler, toWebRequest, localhostHostValidation, localhostOriginValidation } from "@modelcontextprotocol/node";
import { registerTools } from "./tools.mjs";
import { registerResources } from "./resources.mjs";
import { initPairingCode, verifier, handleWellKnown, handleAuthorizeStub, handleTokenStub } from "./auth.mjs";

const HOST = process.env.WHITEBOARD_MCP_HOST || "127.0.0.1";
const PORT = Number(process.env.WHITEBOARD_MCP_PORT || "4319");
const SERVER_URL = new URL(`http://${HOST}:${PORT}/mcp`);

function buildServer() {
  const server = new McpServer({ name: "whiteboard-mcp", version: "0.1.0" });
  registerTools(server);
  registerResources(server);
  return server;
}

const handler = createMcpHandler(buildServer, { legacy: "stateless" });
const nodeHandler = toNodeHandler(handler);
const validateHost = localhostHostValidation();
const validateOrigin = localhostOriginValidation();

async function writeWebResponse(res, webRes) {
  const headers = {};
  for (const [key, value] of webRes.headers) headers[key] = value;
  res.writeHead(webRes.status, headers);
  res.end(await webRes.text());
}

const httpServer = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || `${HOST}:${PORT}`}`);
  if (url.pathname.startsWith("/.well-known/oauth-")) {
    const response = await handleWellKnown(await toWebRequest(req), SERVER_URL);
    if (response) return writeWebResponse(res, response);
    res.writeHead(404); return res.end();
  }
  if (url.pathname === "/authorize") return handleAuthorizeStub(res);
  if (url.pathname === "/token") return handleTokenStub(res);
  if (url.pathname !== "/mcp") { res.writeHead(404); return res.end(); }
  if (!validateHost(req, res) || !validateOrigin(req, res)) return;

  try {
    req.auth = await verifyBearerToken(req.headers.authorization, { verifier, requiredScopes: [] });
  } catch (error) {
    return writeWebResponse(res, bearerAuthChallengeResponse(error));
  }
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

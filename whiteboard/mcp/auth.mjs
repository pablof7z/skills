// Pairing-code authentication seam for the Whiteboard MCP server.
//
// The code is the temporary bearer token. A real OAuth 2.1 authorization
// server can replace the verifier without changing the MCP routing or tools.

import crypto from "node:crypto";
import { OAuthError, OAuthErrorCode, oauthMetadataResponse } from "@modelcontextprotocol/server";

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function generatePairingCode(len = 4) {
  const bytes = crypto.randomBytes(len);
  let out = "";
  for (let i = 0; i < len; i++) out += ALPHABET[bytes[i] % ALPHABET.length];
  return out;
}

let pairingCode = null;
export function initPairingCode() {
  pairingCode = generatePairingCode();
  return pairingCode;
}

export const verifier = {
  async verifyAccessToken(token) {
    if (!pairingCode || token !== pairingCode) {
      throw new OAuthError(OAuthErrorCode.InvalidToken, "invalid or expired token");
    }
    return {
      token,
      clientId: "paired-client",
      scopes: [],
      expiresAt: Math.floor(Date.now() / 1000) + 3600,
    };
  },
};

function oauthMetadataFor(resourceServerUrl) {
  return {
    issuer: resourceServerUrl.origin,
    authorization_endpoint: `${resourceServerUrl.origin}/authorize`,
    token_endpoint: `${resourceServerUrl.origin}/token`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code"],
    code_challenge_methods_supported: ["S256"],
  };
}

export async function handleWellKnown(webReq, resourceServerUrl) {
  return oauthMetadataResponse(webReq, {
    oauthMetadata: oauthMetadataFor(resourceServerUrl),
    resourceServerUrl,
    resourceName: "whiteboard",
    dangerouslyAllowInsecureIssuerUrl: true,
  });
}

function write501(res, what) {
  res.writeHead(501, { "content-type": "application/json" });
  res.end(JSON.stringify({ error: "not_implemented", detail: what }));
}

export function handleAuthorizeStub(res) {
  write501(res, "OAuth authorization is not configured; use the startup pairing code as a bearer token.");
}

export function handleTokenStub(res) {
  write501(res, "OAuth token exchange is not configured; use the startup pairing code as a bearer token.");
}

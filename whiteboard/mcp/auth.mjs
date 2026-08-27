// auth.mjs — pairing-code auth seam for the whiteboard MCP server (skeleton).
//
// The SDK (@modelcontextprotocol/server) is the OAuth 2.1 RESOURCE-SERVER
// half only — it never issues tokens. For the skeleton, the bearer token IS
// the printed pairing code (no separate token store yet): `verifier` below
// is the single seam `verifyBearerToken`/`requireBearerAuth` call into, so a
// real Authorization Server (issuing tokens from POST /token) can replace it
// later without touching server.mjs's request routing or the tool handlers.
//
// TODO(mcp-http-auth): replace `verifier` with a real token store keyed by
// bearer tokens minted from the (currently stubbed) POST /token exchange.
// TODO(mcp-http-auth): /authorize should render an "enter pairing code" form
// and mint a PKCE-bound authorization code; /token should exchange it (RFC
// 7636 PKCE + RFC 8707 resource= binding) for a bearer token.

import crypto from "node:crypto";
import { OAuthError, OAuthErrorCode, oauthMetadataResponse } from "@modelcontextprotocol/server";

// Excludes visually ambiguous chars (0/O, 1/I).
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function generatePairingCode(len = 4) {
  const bytes = crypto.randomBytes(len);
  let out = "";
  for (let i = 0; i < len; i++) out += ALPHABET[bytes[i] % ALPHABET.length];
  return out;
}

// One pairing code per server process lifetime (skeleton — no rotation/expiry).
let pairingCode = null;
export function initPairingCode() {
  pairingCode = generatePairingCode();
  return pairingCode;
}

// OAuthTokenVerifier (@modelcontextprotocol/server): the seam
// verifyBearerToken/requireBearerAuth call into to turn a bearer token into
// an AuthInfo. verifyBearerToken rejects any AuthInfo with no expiresAt (or
// one in the past), so a synthetic near-future expiry is required here.
export const verifier = {
  async verifyAccessToken(token) {
    if (!pairingCode || token !== pairingCode) {
      throw new OAuthError(OAuthErrorCode.InvalidToken, "invalid or expired token");
    }
    return {
      token,
      clientId: "paired-client", // TODO(mcp-http-auth): distinct per-client id once /token exists
      scopes: [],
      expiresAt: Math.floor(Date.now() / 1000) + 3600,
    };
  },
};

// RFC 8414 Authorization Server metadata for THIS server's own (stubbed)
// /authorize + /token routes below. TODO(mcp-http-auth): once a real AS
// exists (possibly external), point these at it instead.
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

// Serves /.well-known/oauth-protected-resource[/mcp] (RFC 9728) and
// /.well-known/oauth-authorization-server (RFC 8414) so conformant clients
// can discover the (stubbed) AS from a 401 challenge. Returns undefined when
// `webReq`'s path is neither well-known route.
export async function handleWellKnown(webReq, resourceServerUrl) {
  return oauthMetadataResponse(webReq, {
    oauthMetadata: oauthMetadataFor(resourceServerUrl),
    resourceServerUrl,
    resourceName: "whiteboard",
    dangerouslyAllowInsecureIssuerUrl: true, // localhost http; skeleton only
  });
}

function write501(res, what) {
  res.writeHead(501, { "content-type": "application/json" });
  res.end(JSON.stringify({ error: "not_implemented", detail: `TODO(mcp-http-auth): ${what}` }));
}

export function handleAuthorizeStub(res) {
  write501(res, "render pairing-code entry, mint a PKCE-bound authorization code, redirect to redirect_uri");
}

export function handleTokenStub(res) {
  write501(res, "exchange authorization_code + PKCE verifier (+ resource= binding) for a bearer token");
}
